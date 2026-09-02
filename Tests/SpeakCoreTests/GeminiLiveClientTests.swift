// swiftlint:disable file_length
import Foundation
import XCTest

@testable import SpeakCore

/// Wire-level coverage for Google Gemini 3.5 Transcribe Live (issue #816).
///
/// Every case drives the client's own receive path with the documented event
/// shapes; no socket is opened, which is also the "connection already gone"
/// path a stop after a dropped connection hits.
final class GeminiLiveClientTests: XCTestCase { // swiftlint:disable:this type_body_length

    // MARK: - Connection

    func testWebSocketURL_usesBidiGenerateContentWithKeyQueryParameter() throws {
        // Act
        let url = try XCTUnwrap(GeminiLiveClient.webSocketURL(apiKey: "gemini-test-key"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        // Assert
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(
            components.path,
            "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "key" })?.value,
            "gemini-test-key"
        )
    }

    func testWebSocketURL_isNilForABlankKey() {
        XCTAssertNil(GeminiLiveClient.webSocketURL(apiKey: "   "))
    }

    /// The Live API only accepts the credential as a query item, so the shared
    /// redactor has to cover it or a URL could reach a log with the key in it.
    func testWebSocketURL_credentialIsRedactedFromLoggableURLs() throws {
        let url = try XCTUnwrap(GeminiLiveClient.webSocketURL(apiKey: "gemini-test-key"))

        let redacted = SensitiveHeaderRedactor.redactSensitiveQueryItems(in: url.absoluteString)

        XCTAssertFalse(redacted.contains("gemini-test-key"))
    }

    // MARK: - Setup message

    func testSetupMessage_usesDocumentedTranscriptionOnlyConfiguration() throws {
        // Act
        let json = try XCTUnwrap(GeminiLiveClient.setupMessageJSON(language: nil))
        let payload = try Self.object(from: json)
        let setup = try XCTUnwrap(payload["setup"] as? [String: Any])
        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let detection = try XCTUnwrap(realtime["automaticActivityDetection"] as? [String: Any])

        // Assert
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        XCTAssertEqual(generation["responseModalities"] as? [String], ["TEXT"])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        // An empty array is the documented "detect automatically" setting.
        XCTAssertEqual(transcription["languageCodes"] as? [String], [])
        XCTAssertNil(transcription["customVocabulary"])
        XCTAssertEqual(detection["disabled"] as? Bool, false)
    }

    func testSetupMessage_mapsAppLocaleOntoBCP47LanguageCodes() throws {
        // Act
        let json = try XCTUnwrap(GeminiLiveClient.setupMessageJSON(language: "en_GB"))
        let setup = try XCTUnwrap(try Self.object(from: json)["setup"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])

        // Assert
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["en-GB"])
    }

    func testSetupMessage_boundsCustomVocabularyAndDropsBlankTerms() throws {
        // Arrange: blanks plus more than the documented 1,000-term cap.
        let terms = ["Speak", "  ", "Gemini"] + (0..<1_200).map { "term-\($0)" }

        // Act
        let json = try XCTUnwrap(
            GeminiLiveClient.setupMessageJSON(language: nil, customVocabulary: terms)
        )
        let setup = try XCTUnwrap(try Self.object(from: json)["setup"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        let vocabulary = try XCTUnwrap(transcription["customVocabulary"] as? [String])

        // Assert
        XCTAssertEqual(vocabulary.count, 1_000)
        XCTAssertEqual(Array(vocabulary.prefix(2)), ["Speak", "Gemini"])
    }

    func testSetupMessage_smartModeUsesUppercaseWireSpelling() throws {
        let json = try XCTUnwrap(GeminiLiveClient.setupMessageJSON(language: nil, mode: .smart))
        let setup = try XCTUnwrap(try Self.object(from: json)["setup"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])

        XCTAssertEqual(transcription["mode"] as? String, "SMART")
    }

    // MARK: - Audio framing

    func testAudioChunk_isBase64PCMWithTheRateInTheMIMEType() throws {
        // Arrange: two little-endian PCM16 samples.
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])

        // Act
        let json = try XCTUnwrap(GeminiLiveClient.audioChunkJSON(pcm, sampleRate: 16_000))
        let realtime = try XCTUnwrap(try Self.object(from: json)["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])

        // Assert
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"] as? String)), pcm)
    }

    func testAudioStreamEnd_usesDocumentedShape() {
        XCTAssertEqual(
            GeminiLiveClient.audioStreamEndJSON(),
            #"{"realtimeInput":{"audioStreamEnd":true}}"#
        )
    }

    // MARK: - Event parsing

    func testTranscriptEvent_parsesInterimTranscription() {
        let event = GeminiLiveClient.transcriptEvent(from: Self.interim("Hello wor"))

        XCTAssertEqual(event, GeminiLiveTranscriptEvent(text: "Hello wor", isFinal: false))
    }

    func testTranscriptEvent_parsesFinalTranscription() {
        let event = GeminiLiveClient.transcriptEvent(from: Self.final("Hello world."))

        XCTAssertEqual(event, GeminiLiveTranscriptEvent(text: "Hello world.", isFinal: true))
    }

    func testTranscriptEvent_ignoresBlankTextAndNonTranscriptFrames() {
        XCTAssertNil(GeminiLiveClient.transcriptEvent(from: Self.final("   ")))
        XCTAssertNil(GeminiLiveClient.transcriptEvent(from: #"{"setupComplete":{}}"#))
        XCTAssertNil(
            GeminiLiveClient.transcriptEvent(from: #"{"serverContent":{"turnComplete":true}}"#)
        )
        XCTAssertNil(GeminiLiveClient.transcriptEvent(from: "not json at all"))
    }

    /// The output transcription is the model *speaking*; Speak never requests a
    /// response, but a stray frame must never be mistaken for dictated text.
    func testTranscriptEvent_ignoresOutputTranscription() {
        let json = #"{"serverContent":{"outputTranscription":{"text":"assistant speech"}}}"#

        XCTAssertNil(GeminiLiveClient.transcriptEvent(from: json))
    }

    func testServerSignal_decodesSetupCompleteTurnCompleteAndGoAway() {
        XCTAssertEqual(GeminiLiveClient.serverSignal(from: #"{"setupComplete":{}}"#), .setupComplete)
        XCTAssertEqual(
            GeminiLiveClient.serverSignal(from: #"{"serverContent":{"turnComplete":true}}"#),
            .turnComplete
        )
        XCTAssertEqual(
            GeminiLiveClient.serverSignal(from: #"{"goAway":{"timeLeft":"5s"}}"#),
            .goAway
        )
        XCTAssertNil(GeminiLiveClient.serverSignal(from: Self.final("Hello.")))
    }

    // MARK: - Error mapping

    func testErrorMapping_unauthenticatedBecomesInvalidAPIKey() throws {
        let json = """
        {"error": {"code": 401, "message": "API key not valid", "status": "UNAUTHENTICATED"}}
        """
        guard case .failure(let code, let status, let message) =
            try XCTUnwrap(GeminiLiveClient.serverSignal(from: json)) else {
            return XCTFail("Expected a failure signal")
        }

        let mapped = GeminiLiveClient.mapServerFailure(code: code, status: status, message: message)

        Self.assertInvalidGeminiAPIKey(mapped)
    }

    func testErrorMapping_permissionDeniedBecomesInvalidAPIKey() {
        let mapped = GeminiLiveClient.mapServerFailure(
            code: 403, status: "PERMISSION_DENIED", message: "no preview access"
        )

        Self.assertInvalidGeminiAPIKey(mapped)
    }

    func testErrorMapping_resourceExhaustedBecomesRateLimited() {
        let mapped = GeminiLiveClient.mapServerFailure(
            code: 429, status: "RESOURCE_EXHAUSTED", message: "quota exceeded"
        )

        XCTAssertEqual(mapped as? GeminiLiveError, .rateLimited("quota exceeded"))
    }

    /// The REST error reference spells `code` as a snake_case string; the same
    /// envelope can reach the socket, so both spellings must map alike.
    func testErrorMapping_snakeCaseCodeStillMapsToRateLimited() throws {
        let json = """
        {"error": {"code": "rate_limit_exceeded", "message": "slow down"}}
        """
        guard case .failure(let code, let status, let message) =
            try XCTUnwrap(GeminiLiveClient.serverSignal(from: json)) else {
            return XCTFail("Expected a failure signal")
        }

        XCTAssertNil(code)
        XCTAssertEqual(status, "rate_limit_exceeded")
        XCTAssertEqual(
            GeminiLiveClient.mapServerFailure(code: code, status: status, message: message)
                as? GeminiLiveError,
            .rateLimited("slow down")
        )
    }

    func testErrorMapping_unknownFailureKeepsTheServerDetail() {
        let mapped = GeminiLiveClient.mapServerFailure(
            code: 500, status: "INTERNAL", message: "boom"
        )

        XCTAssertEqual(
            mapped as? GeminiLiveError,
            .server(code: 500, status: "INTERNAL", message: "boom")
        )
        XCTAssertEqual(
            (mapped as? GeminiLiveError)?.errorDescription,
            "Gemini transcription failed (HTTP 500): boom"
        )
    }

    func testMalformedFrame_isIgnoredRatherThanSurfacedAsAnError() {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        let observer = CallbackObserver()
        client.beginSession(
            onTranscript: { text, isFinal in observer.record(text: text, isFinal: isFinal) },
            onError: { observer.record(error: $0) }
        )

        // Act
        client.ingest("{ this is not json")
        client.ingest(#"{"serverContent":{}}"#)

        // Assert
        XCTAssertTrue(observer.transcripts.isEmpty)
        XCTAssertTrue(observer.errors.isEmpty)
    }

    func testServerError_reachesTheErrorCallback() {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        let observer = CallbackObserver()
        client.beginSession(
            onTranscript: { text, isFinal in observer.record(text: text, isFinal: isFinal) },
            onError: { observer.record(error: $0) }
        )

        // Act
        client.ingest(
            #"{"error":{"code":429,"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#
        )

        // Assert
        XCTAssertEqual(observer.errors.count, 1)
        XCTAssertEqual(observer.errors.first as? GeminiLiveError, .rateLimited("quota exceeded"))
    }

    // MARK: - Session behaviour

    func testStart_deliversInterimsAndFinalsToTheCallback() {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        let observer = CallbackObserver()
        client.beginSession(
            onTranscript: { text, isFinal in observer.record(text: text, isFinal: isFinal) },
            onError: { observer.record(error: $0) }
        )

        // Act
        client.ingest(Self.interim("Hello wor"))
        client.ingest(Self.final("Hello world."))

        // Assert
        XCTAssertEqual(
            observer.transcripts.map(\.text), ["Hello wor", "Hello world."]
        )
        XCTAssertEqual(observer.transcripts.map(\.isFinal), [false, true])
        XCTAssertTrue(observer.errors.isEmpty)
    }

    func testFinishAndWait_returnsTheWholeSessionNotTheTrailingUtterance() async {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        // Act: three finalised utterances, as the Live API streams them.
        client.ingest(Self.final("Hello there."))
        client.ingest(Self.interim("this is"))
        client.ingest(Self.final("This is a test."))
        client.ingest(Self.final("Goodbye."))
        let transcript = await client.finishAndWait()

        // Assert
        XCTAssertEqual(transcript, "Hello there. This is a test. Goodbye.")
    }

    func testFinishAndWait_withoutAnySpeechReturnsNil() async {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        // Act: interim-only sessions have nothing final to hand back.
        client.ingest(Self.interim("um"))

        // Assert
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    /// Issue #700: two standalone finals with identical text are two
    /// utterances, never a resend.
    func testFinishAndWait_keepsRepeatedIdenticalFinals() async {
        let client = GeminiLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        client.ingest(Self.final("Yes."))
        client.ingest(Self.final("Yes."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
    }

    func testStop_isIdempotentAndSilencesLaterFrames() async {
        // Arrange
        let client = GeminiLiveClient(apiKey: "k")
        let observer = CallbackObserver()
        client.beginSession(
            onTranscript: { text, isFinal in observer.record(text: text, isFinal: isFinal) },
            onError: { observer.record(error: $0) }
        )
        client.ingest(Self.final("Hello."))

        // Act
        client.stop()
        client.stop()
        let transcript = await client.finishAndWait()

        // Assert: cancellation keeps what was already transcribed and never
        // reports an error for the teardown itself.
        XCTAssertEqual(transcript, "Hello.")
        XCTAssertTrue(observer.errors.isEmpty)
    }

    func testBeginSessionResetsTheAccumulatorBetweenRecordings() async {
        // Arrange: controllers are cached and reused between recordings.
        let client = GeminiLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.ingest(Self.final("First recording."))
        _ = await client.finishAndWait()

        // Act
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.ingest(Self.final("Second recording."))

        // Assert
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Second recording.")
    }

    func testClientDeclaresItsStopContract() {
        let client = GeminiLiveClient(apiKey: "k")

        XCTAssertEqual(client.finalShape, .standaloneSegments)
        // `audioStreamEnd` flushes audio the server has not transcribed yet, so
        // a stop must always drain rather than close immediately.
        XCTAssertTrue(client.finishFlushesBufferedAudio)
    }

    // MARK: - Fixtures

    /// `StreamingClientError` is deliberately not `Equatable` (it is a
    /// `LocalizedError` the UI renders), so the assertion matches the case.
    private static func assertInvalidGeminiAPIKey(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case StreamingClientError.invalidAPIKey(let provider) = error else {
            return XCTFail("Expected invalidAPIKey, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(provider, "Google Gemini", file: file, line: line)
    }

    private static func interim(_ text: String) -> String {
        #"{"serverContent":{"interimInputTranscription":{"text":"\#(text)"}}}"#
    }

    private static func final(_ text: String) -> String {
        #"{"serverContent":{"inputTranscription":{"text":"\#(text)"}}}"#
    }

    private static func object(from json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Collects callback deliveries from the client's receive path.
    private final class CallbackObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var storedTranscripts: [(text: String, isFinal: Bool)] = []
        private var storedErrors: [Error] = []

        var transcripts: [(text: String, isFinal: Bool)] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storedTranscripts
        }

        var errors: [Error] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storedErrors
        }

        func record(text: String, isFinal: Bool) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedTranscripts.append((text, isFinal))
        }

        func record(error: Error) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedErrors.append(error)
        }
    }
}
