import Foundation
import XCTest

@testable import SpeakCore

/// Protocol tests for the shared Mistral Voxtral Realtime client.
///
/// Voxtral is the one provider here that carries audio as base64 inside JSON
/// text frames and emits no per-utterance final, so the delta folding and the
/// terminal `transcription.done` handling are what these tests pin down.
final class MistralVoxtralLiveClientTests: XCTestCase {

    // MARK: - Request

    func testWebSocketURL_carriesTheModelAsItsOnlyQueryParameter() throws {
        let url = try XCTUnwrap(
            MistralVoxtralLiveClient.webSocketURL(model: MistralVoxtralRealtime.apiModelID)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.mistral.ai")
        XCTAssertEqual(components.path, "/v1/audio/transcriptions/realtime")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "model", value: "voxtral-mini-transcribe-realtime-2602")]
        )
    }

    func testCatalogueIdentifierResolvesToTheDatedModelID() throws {
        let route = try XCTUnwrap(
            LiveTranscriptionRouting.route(for: MistralVoxtralRealtime.liveCatalogID)
        )

        XCTAssertEqual(route.provider, .mistral)
        XCTAssertEqual(route.apiModelName, MistralVoxtralRealtime.apiModelID)
        XCTAssertEqual(route.apiKeyIdentifier, "mistral.apiKey")
    }

    func testSessionUpdateDeclaresThePCMFormatAndStreamingDelay() throws {
        let payload = MistralVoxtralLiveClient.sessionUpdatePayload(sampleRate: 16_000)

        XCTAssertEqual(payload["type"] as? String, "session.update")
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        let format = try XCTUnwrap(session["audio_format"] as? [String: Any])
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(format["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(session["target_streaming_delay_ms"] as? Int, 480)
        // There is no language field in this protocol: Voxtral detects the
        // language and reports it back as `transcription.language`.
        XCTAssertNil(session["language"])
    }

    // MARK: - Audio framing

    func testAudioIsChunkedBelowTheDecodedCapBeforeBase64Encoding() throws {
        let audio = Data(repeating: 7, count: MistralVoxtralRealtime.maximumAppendBytes + 1_000)
        let payloads = MistralVoxtralLiveClient.appendPayloads(for: audio)

        XCTAssertEqual(payloads.count, 2)
        var rebuilt = Data()
        for payload in payloads {
            XCTAssertEqual(payload["type"] as? String, "input_audio.append")
            let encoded = try XCTUnwrap(payload["audio"] as? String)
            let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
            // The cap is on the decoded length, so chunking must happen first.
            XCTAssertLessThanOrEqual(decoded.count, MistralVoxtralRealtime.maximumAppendBytes)
            rebuilt.append(decoded)
        }
        XCTAssertEqual(rebuilt, audio)
    }

    func testASingleSmallChunkBecomesOneAppendMessage() throws {
        let audio = Data(repeating: 3, count: 640)
        let payloads = MistralVoxtralLiveClient.appendPayloads(for: audio)

        XCTAssertEqual(payloads.count, 1)
        let encoded = try XCTUnwrap(payloads[0]["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), audio)
    }

    func testEmptyAudioProducesNoAppendMessages() {
        XCTAssertTrue(MistralVoxtralLiveClient.appendPayloads(for: Data()).isEmpty)
    }

    func testAudioBeforeSessionCreatedIsHeldNotDropped() {
        // Issue #641: the session must be configured before any audio, so the
        // user's opening words are held across the handshake.
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        XCTAssertFalse(client.isSessionReady)
        client.sendAudio(Data(repeating: 1, count: 640))
        client.sendAudio(Data(repeating: 2, count: 640))

        XCTAssertEqual(client.preroll.snapshot.chunkCount, 2)
        XCTAssertEqual(client.preroll.snapshot.droppedChunkCount, 0)
    }

    func testEmptyAudioChunksAreNotBuffered() {
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })

        client.sendAudio(Data())

        XCTAssertTrue(client.preroll.isEmpty)
    }

    // MARK: - Delta folding

    func testDeltasAreAppendOnlyAndReportedCumulatively() async {
        // The service sends fragments; every other provider here reports
        // cumulative interim text, so the folding happens in the client.
        var events: [(String, Bool)] = []
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { events.append(($0, $1)) }, onError: { _ in })

        client.ingest(Self.delta("Hello"))
        client.ingest(Self.delta(" there"))
        client.ingest(Self.delta(", world."))

        XCTAssertEqual(events.map(\.0), ["Hello", "Hello there", "Hello there, world."])
        XCTAssertTrue(events.allSatisfy { !$0.1 })
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Hello there, world.")
    }

    func testTranscriptionDoneReplacesTheFoldedDeltasRatherThanExtendingThem() async {
        let client = Self.armedClient()

        client.ingest(Self.delta("helo"))
        client.ingest(Self.delta(" wrld"))
        client.ingest(Self.done("Hello world."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Hello world.")
    }

    func testTranscriptionDoneResolvesAnArmedFinishImmediately() async {
        let client = Self.armedClient()
        client.ingest(Self.delta("Committed"))

        let transcript = await client.awaitFinalTranscript(budget: 30) {
            client.ingest(Self.done("Committed."))
        }

        XCTAssertEqual(transcript, "Committed.")
    }

    func testADoneConsumedByFinishIsNotAlsoDeliveredAsAFinal() async {
        // Delivering it twice would double the transcript for a consumer that
        // appends what it is handed.
        var finals: [String] = []
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(
            onTranscript: { text, isFinal in if isFinal { finals.append(text) } },
            onError: { _ in }
        )

        let transcript = await client.awaitFinalTranscript(budget: 30) {
            client.ingest(Self.done("Only once."))
        }

        XCTAssertEqual(transcript, "Only once.")
        XCTAssertTrue(finals.isEmpty)
    }

    func testADoneOutsideAFinishIsDeliveredAsAFinal() async {
        var finals: [String] = []
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(
            onTranscript: { text, isFinal in if isFinal { finals.append(text) } },
            onError: { _ in }
        )

        client.ingest(Self.done("Delivered."))

        XCTAssertEqual(finals, ["Delivered."])
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Delivered.")
    }

    func testALostDoneFrameStillReturnsTheFoldedDeltas() async {
        // Truncating the tail is a known defect class here (issues #947, #949):
        // a session that never receives its terminal frame must still hand back
        // everything it heard.
        let client = Self.armedClient()

        client.ingest(Self.delta("Everything I said"))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Everything I said")
    }

    func testEmptyAudioSessionFinishesWithNoTranscript() async {
        let client = Self.armedClient()

        client.ingest(Self.delta("   "))
        client.ingest(Self.done("  "))

        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    func testUnhandledEventsNeverEndTheSession() async {
        let client = Self.armedClient()

        client.ingest(Self.sessionUpdated)
        client.ingest(#"{"type":"transcription.language","audio_language":"en"}"#)
        client.ingest(#"{"type":"transcription.segment","text":"seg","start":0.0,"end":1.4,"speaker_id":null}"#)
        client.ingest(#"{"type":"something.new.upstream"}"#)
        client.ingest(Self.delta("Still here."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Still here.")
    }

    func testANullableSegmentTimestampIsNotAParseFailure() async {
        // `start`/`end` are nullable in Mistral's own models even though the
        // published schema types them as numbers.
        let client = Self.armedClient()

        client.ingest(#"{"type":"transcription.segment","text":"seg","start":null,"end":null}"#)
        client.ingest(Self.delta("Fine."))

        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Fine.")
    }

    // MARK: - Failures

    func testAServerErrorEventEndsTheSession() {
        var failure: Error?
        let client = Self.armedClient(onError: { failure = $0 })

        client.ingest(Self.sessionCreated)
        client.ingest(#"{"type":"error","error":{"message":"bad request","code":400}}"#)

        XCTAssertEqual(
            failure as? MistralRealtimeError, .server(message: "bad request", code: 400)
        )
    }

    func testAnErrorBeforeSessionCreatedIsAHandshakeRejection() {
        // Authentication and entitlement failures arrive this way, before the
        // session exists.
        var failure: Error?
        let client = Self.armedClient(onError: { failure = $0 })

        client.ingest(#"{"type":"error","error":{"message":"unauthorized","code":401}}"#)

        XCTAssertEqual(
            failure as? MistralRealtimeError, .handshakeRejected(message: "unauthorized")
        )
    }

    func testAnObjectShapedErrorMessageIsReadFromItsDetail() {
        var failure: Error?
        let client = Self.armedClient(onError: { failure = $0 })

        client.ingest(Self.sessionCreated)
        client.ingest(#"{"type":"error","error":{"message":{"detail":"quota exhausted"},"code":429}}"#)

        XCTAssertEqual(
            failure as? MistralRealtimeError, .server(message: "quota exhausted", code: 429)
        )
    }

    func testMissingAPIKeyFailsBeforeAnySocketIsOpened() {
        var failure: Error?
        MistralVoxtralLiveClient(apiKey: " ").start(onTranscript: { _, _ in }, onError: { failure = $0 })

        guard case .missingAPIKey(let provider)? = failure as? StreamingClientError else {
            return XCTFail("expected a missing-key error, got \(String(describing: failure))")
        }
        XCTAssertEqual(provider, "Mistral")
    }

    func testCancellationClearsHeldAudioAndResolvesAWaiter() async {
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 0, count: 640))
        XCTAssertFalse(client.preroll.isEmpty)

        client.stop()

        XCTAssertTrue(client.preroll.isEmpty)
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }

    // MARK: - Fixtures

    private static func armedClient(
        onError: @escaping (Error) -> Void = { _ in }
    ) -> MistralVoxtralLiveClient {
        let client = MistralVoxtralLiveClient(apiKey: "k")
        client.beginSession(onTranscript: { _, _ in }, onError: onError)
        return client
    }

    private static let sessionUpdated = """
    {"type":"session.updated","session":{"request_id":"ws-1","model":"m",\
    "audio_format":{"encoding":"pcm_s16le","sample_rate":16000},\
    "target_streaming_delay_ms":480}}
    """

    private static let sessionCreated = """
    {"type":"session.created","session":{"request_id":"ws-123456",\
    "model":"voxtral-mini-transcribe-realtime-2602",\
    "audio_format":{"encoding":"pcm_s16le","sample_rate":16000},\
    "target_streaming_delay_ms":null}}
    """

    private static func delta(_ text: String) -> String {
        #"{"type":"transcription.text.delta","text":"\#(text)"}"#
    }

    private static func done(_ text: String) -> String {
        """
        {"type":"transcription.done","model":"voxtral-mini-transcribe-realtime-2602",\
        "text":"\(text)","language":"en","segments":[],\
        "usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,\
        "prompt_audio_seconds":12,"service_tier":null}}
        """
    }
}
