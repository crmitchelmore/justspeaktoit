import Foundation
import XCTest

@testable import SpeakCore

/// The realtime half of xAI's dedicated speech-to-text service: the session
/// URL, the `is_final` / `speech_final` semantics, and the `audio.done` ->
/// `transcript.done` finalisation.
final class XAISpeechToTextLiveClientTests: XCTestCase {

    // MARK: - Realtime protocol

    func testWebSocketURL_configuresTheSessionThroughQueryItemsOnly() throws {
        let url = try XCTUnwrap(XAISpeechToTextLiveClient.webSocketURL(
            sampleRate: 24_000, language: "en_US", keywords: ["Speak", "xAI"]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/stt")
        XCTAssertEqual(items.first { $0.name == "encoding" }?.value, "pcm")
        XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, "24000")
        XCTAssertEqual(items.first { $0.name == "interim_results" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "en")
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.map(\.value), ["Speak", "xAI"])
        // No model parameter exists on this endpoint.
        XCTAssertNil(items.first { $0.name == "model" })
    }

    func testEventDecoding_mapsTheDocumentedIsFinalAndSpeechFinalPairs() throws {
        func event(_ json: String) throws -> XAISpeechToTextEvent {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(XAISpeechToTextEvent(object: object))
        }

        XCTAssertEqual(try event(#"{"type":"transcript.created"}"#), .created)
        XCTAssertEqual(
            try event(
                #"{"type":"transcript.partial","text":"Hel","is_final":false,"speech_final":false}"#
            ),
            .partial(text: "Hel", isFinal: false, speechFinal: false, eventID: nil)
        )
        XCTAssertEqual(
            try event(
                """
                {"type":"transcript.partial","text":"Hello there","is_final":true,
                 "speech_final":false,"start":1.5}
                """
            ),
            .partial(text: "Hello there", isFinal: true, speechFinal: false, eventID: "0:1.5")
        )
        XCTAssertEqual(
            try event(
                """
                {"type":"transcript.partial","text":"Hello there.","is_final":true,
                 "speech_final":true,"start":1.5,"channel_index":1}
                """
            ),
            .partial(text: "Hello there.", isFinal: true, speechFinal: true, eventID: "1:1.5")
        )
        XCTAssertEqual(
            try event(#"{"type":"transcript.done","text":"Hello there. Goodbye.","duration":4}"#),
            .done(text: "Hello there. Goodbye.")
        )
        XCTAssertEqual(
            try event(#"{"type":"error","message":"Invalid API key"}"#),
            .failure(message: "Invalid API key")
        )
        // A frame the client does not know must be ignored, never fatal.
        let unknown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"type":"keepalive"}"#.utf8)) as? [String: Any]
        )
        XCTAssertNil(XAISpeechToTextEvent(object: unknown))
    }

    func testLiveClient_declaresStandaloneChunkFinalsAndFoldsThemIntoOneTranscript() async {
        let client = XAISpeechToTextLiveClient(apiKey: "k")
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertTrue(client.finishFlushesBufferedAudio)

        let observer = XAITranscriptObserver()
        client.beginSession(
            onTranscript: { text, isFinal in observer.record(text, isFinal) },
            onError: { _ in XCTFail("unexpected error") }
        )
        client.ingest(Self.partial("Hello", isFinal: false, start: 0))
        client.ingest(Self.partial("Hello there.", isFinal: true, start: 0))
        client.ingest(Self.partial("Hello there.", isFinal: true, start: 0))
        client.ingest(Self.partial("Goodbye.", isFinal: true, start: 3))

        // The socket is already gone here, which is the stop-after-drop path.
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Hello there. Goodbye.")
        // The retransmitted chunk is dropped by event identity, not by text.
        XCTAssertEqual(observer.finals, ["Hello there.", "Goodbye."])
        XCTAssertEqual(observer.interims, ["Hello"])
    }

    /// `transcript.done` is authoritative for the whole session, so it replaces
    /// the folded chunks rather than being appended to them.
    func testLiveClient_finalTranscriptReplacesTheFoldedChunkFinals() async {
        let client = XAISpeechToTextLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.ingest(Self.partial("hello there", isFinal: true, start: 0))

        let started = Date()
        let transcript = await client.awaitFinalTranscript(budget: 5) {
            client.ingest(#"{"type":"transcript.done","text":"Hello there.","duration":2}"#)
        }
        XCTAssertEqual(transcript, "Hello there.")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the done frame must resolve the finish rather than the budget"
        )
    }

    func testLiveClient_sessionWithoutSpeechReturnsNilRatherThanEmptyText() async {
        let client = XAISpeechToTextLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.ingest(#"{"type":"transcript.created"}"#)
        client.ingest(Self.partial("um", isFinal: false, start: 0))
        client.ingest(#"{"type":"transcript.done","text":"","duration":0}"#)

        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testLiveClient_reportsAMissingKeyAndDoesNotOpenASocket() {
        let client = XAISpeechToTextLiveClient(apiKey: "   ")
        var reported: Error?
        client.start(onTranscript: { _, _ in }, onError: { reported = $0 })

        XCTAssertEqual(
            reported?.localizedDescription,
            StreamingClientError.missingAPIKey(provider: "xAI").localizedDescription
        )
        XCTAssertFalse(client.isSessionReady)
    }

    func testLiveClient_holdsAudioUntilTheServerSaysItIsReady() {
        let client = XAISpeechToTextLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        XCTAssertFalse(client.isSessionReady)

        // xAI requires transcript.created before audio, so what the user said
        // during the handshake is buffered rather than dropped.
        client.sendAudio(Data(repeating: 0, count: 640))
        client.ingest(#"{"type":"transcript.created"}"#)
        XCTAssertTrue(client.isSessionReady)
    }

    func testLiveClient_classifiesServerErrorFramesFromTheirWording() {
        XCTAssertEqual(
            XAISpeechToTextLiveClient.error(fromServerMessage: "Invalid API key").localizedDescription,
            StreamingClientError.invalidAPIKey(provider: "xAI").localizedDescription
        )
        XCTAssertEqual(
            XAISpeechToTextLiveClient.error(fromServerMessage: "no credit remaining")
                as? XAISpeechToTextError,
            .quotaExceeded(message: "no credit remaining")
        )
        XCTAssertEqual(
            XAISpeechToTextLiveClient.error(fromServerMessage: "rate limit exceeded")
                as? XAISpeechToTextError,
            .rateLimited(message: "rate limit exceeded")
        )
        XCTAssertEqual(
            XAISpeechToTextLiveClient.error(fromServerMessage: "backend unavailable")
                as? XAISpeechToTextError,
            .server(message: "backend unavailable")
        )
    }

    func testLiveClient_surfacesAnErrorFrameToTheSession() {
        let client = XAISpeechToTextLiveClient(apiKey: "k")
        var reported: Error?
        client.beginSession(onTranscript: { _, _ in }, onError: { reported = $0 })
        client.ingest(#"{"type":"error","message":"Invalid API key"}"#)

        XCTAssertEqual(
            reported?.localizedDescription,
            StreamingClientError.invalidAPIKey(provider: "xAI").localizedDescription
        )
    }

    // MARK: - Fixtures

    private static func partial(_ text: String, isFinal: Bool, start: Double) -> String {
        """
        {"type":"transcript.partial","text":"\(text)","is_final":\(isFinal),
         "speech_final":\(isFinal),"start":\(start),"duration":1}
        """
    }
}

private final class XAITranscriptObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var finalTexts: [String] = []
    private var interimTexts: [String] = []

    var finals: [String] {
        lock.lock()
        defer { lock.unlock() }
        return finalTexts
    }

    var interims: [String] {
        lock.lock()
        defer { lock.unlock() }
        return interimTexts
    }

    func record(_ text: String, _ isFinal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isFinal { finalTexts.append(text) } else { interimTexts.append(text) }
    }
}
