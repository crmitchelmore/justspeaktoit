import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Wire format and contract of the shared Gladia live route, checked against
/// https://docs.gladia.io/api-reference/v2/live/init and the live AsyncAPI
/// schema (https://github.com/gladiaio/docs/blob/main/asyncapi.yaml).
final class GladiaLiveProtocolTests: XCTestCase {
    func testSessionRequestUsesTheDocumentedEndpointHeadersAndPCMConfiguration() throws {
        let harness = GladiaHarness(apiKey: "  synthetic-key \n")
        harness.start()
        let request = try XCTUnwrap(harness.sessions.requests.first)
        XCTAssertEqual(request.urlRequest.url?.absoluteString, "https://api.gladia.io/v2/live")
        XCTAssertEqual(request.urlRequest.httpMethod, "POST")
        XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "x-gladia-key"), "synthetic-key")
        XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.urlRequest.value(forHTTPHeaderField: "Authorization"))
        let body = request.jsonBody
        XCTAssertEqual(body["model"] as? String, "solaria-1")
        XCTAssertEqual(body["encoding"] as? String, "wav/pcm")
        XCTAssertEqual(body["bit_depth"] as? Int, 16)
        XCTAssertEqual(body["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(body["channels"] as? Int, 1)
        let messages = try XCTUnwrap(body["messages_config"] as? [String: Bool])
        XCTAssertEqual(messages, [
            "receive_partial_transcripts": true, "receive_final_transcripts": true,
            "receive_speech_events": false, "receive_pre_processing_events": false,
            "receive_realtime_processing_events": false, "receive_post_processing_events": false,
            "receive_acknowledgments": false, "receive_errors": true, "receive_lifecycle_events": true
        ])
        XCTAssertEqual(Set(body.keys), [
            "model", "encoding", "bit_depth", "sample_rate", "channels", "language_config", "messages_config"
        ])
        XCTAssertTrue(harness.sockets.sockets.isEmpty, "The socket waits for the session reply")
        harness.client.cancel()
    }

    func testLanguageSelectionMapsToGladiasLanguageConfiguration() {
        for automatic in [nil, "", "  ", "Automatic", "automatic", "auto"] as [String?] {
            let config = GladiaLiveProtocol.languageConfig(for: automatic)
            XCTAssertEqual(config["languages"] as? [String], [], "\(String(describing: automatic))")
            XCTAssertEqual(config["code_switching"] as? Bool, true)
        }
        for (selection, code) in [("en_GB", "en"), ("fr-FR", "fr"), (" de_DE ", "de"), ("ja", "ja"), ("zh_TW", "zh")] {
            let config = GladiaLiveProtocol.languageConfig(for: selection)
            XCTAssertEqual(config["languages"] as? [String], [code], selection)
            XCTAssertEqual(config["code_switching"] as? Bool, false)
        }
        let harness = GladiaHarness(model: "gladia/solaria-1-streaming", language: "en_GB")
        harness.start()
        let body = harness.sessions.requests.first?.jsonBody ?? [:]
        XCTAssertEqual(body["model"] as? String, "solaria-1")
        XCTAssertEqual((body["language_config"] as? [String: Any])?["languages"] as? [String], ["en"])
        harness.client.cancel()
    }

    func testCatalogueAndAPIModelNamesResolveToTheLiveModel() {
        XCTAssertEqual(GladiaLiveProtocol.apiModelName(from: "gladia/solaria-1-streaming"), "solaria-1")
        XCTAssertEqual(GladiaLiveProtocol.apiModelName(from: "solaria-1"), "solaria-1")
        XCTAssertEqual(GladiaLiveProtocol.apiModelName(from: "  "), GladiaLive.defaultModel)
        let route = LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming")
        XCTAssertEqual(route?.provider, .gladia)
        XCTAssertEqual(route?.apiModelName, GladiaLive.defaultModel)
        XCTAssertEqual(route?.apiKeyIdentifier, "gladia.apiKey")
        XCTAssertEqual(route?.sampleRate, 16_000)
    }

    func testSessionReplyAcceptsCreatedSessionsAndTypesEveryRejection() throws {
        let endpoint = URL(string: "https://api.gladia.io/v2/live")!
        let granted = Data(GladiaFakeSessions.grantJSON(url: GladiaHarness.sessionURL).utf8)
        for status in [200, 201] {
            let url = try GladiaLiveProtocol.sessionURL(statusCode: status, body: granted, endpoint: endpoint).get()
            XCTAssertEqual(url.absoluteString, GladiaHarness.sessionURL)
        }
        for status in [401, 403] {
            XCTAssertEqual(rejection(status, #"{"message":"Invalid key"}"#, endpoint)?.localizedDescription,
                           StreamingClientError.invalidAPIKey(provider: "Gladia").localizedDescription)
        }
        let unprocessable = #"{"statusCode":422,"message":"sample_rate must be valid"}"#
        XCTAssertEqual(rejection(422, unprocessable, endpoint) as? GladiaStreamingError,
                       .sessionRejected(statusCode: 422, message: "sample_rate must be valid"))
        XCTAssertEqual(rejection(500, "<html>upstream</html>", endpoint) as? GladiaStreamingError,
                       .sessionRejected(statusCode: 500, message: nil))
        let long = String(repeating: "x", count: 500)
        guard case .sessionRejected(_, let message)? = rejection(400, #"{"message":"\#(long)"}"#, endpoint)
            as? GladiaStreamingError else { return XCTFail("Expected a rejection") }
        XCTAssertEqual(message?.count, GladiaLiveProtocol.maximumServerMessageLength)
        for malformed in ["not json", "{}", #"{"id":"x"}"#, #"{"url":42}"#, #"{"url":""}"#] {
            XCTAssertEqual(rejection(201, malformed, endpoint) as? GladiaStreamingError, .invalidSessionResponse,
                           malformed)
        }
    }

    func testSessionURLMustStayOnTheEndpointsSecureTrustBoundary() {
        let gladia = URL(string: "https://api.gladia.io/v2/live")!
        for trusted in ["wss://api.gladia.io/v2/live?token=t", "wss://api-eu-west.gladia.io/v2/live?token=t",
                        "WSS://API.GLADIA.IO/v2/live?token=t"] {
            XCTAssertTrue(GladiaLiveProtocol.isTrustedSessionURL(URL(string: trusted)!, endpoint: gladia), trusted)
        }
        for untrusted in ["ws://api.gladia.io/v2/live?token=t", "https://api.gladia.io/v2/live?token=t",
                          "wss://gladia.io.example.com/v2/live", "wss://evilgladia.io/v2/live",
                          "wss://user:secret@api.gladia.io/v2/live", "wss://127.0.0.1/v2/live",
                          "file:///tmp/socket", "wss:///v2/live"] {
            let url = URL(string: untrusted)
            XCTAssertFalse(url.map { GladiaLiveProtocol.isTrustedSessionURL($0, endpoint: gladia) } ?? false, untrusted)
        }
        let loopback = URL(string: "http://127.0.0.1:8123/gladia/v2/live")!
        XCTAssertTrue(GladiaLiveProtocol.isTrustedSessionURL(
            URL(string: "ws://127.0.0.1:8123/gladia/live?token=t")!, endpoint: loopback))
        XCTAssertFalse(GladiaLiveProtocol.isTrustedSessionURL(
            URL(string: "ws://localhost:8123/gladia/live")!, endpoint: loopback), "Host must match")
        XCTAssertFalse(GladiaLiveProtocol.isTrustedSessionURL(
            URL(string: "ws://127.0.0.1:8123/live")!, endpoint: URL(string: "https://127.0.0.1/v2/live")!),
            "A secure endpoint never downgrades its socket")
        XCTAssertFalse(GladiaLiveProtocol.isTrustedSessionURL(
            URL(string: "ws://api.gladia.io/live")!, endpoint: URL(string: "http://api.gladia.io/v2/live")!),
            "Plain sockets are for the loopback peer only")
    }

    func testServerFramesDecodeTranscriptsLifecycleAndErrors() {
        let unicode = "Café — naïve 👩🏽‍💻 界"
        XCTAssertEqual(event(GladiaFrames.transcript(" \(unicode) ", id: "00-01", isFinal: false)),
                       .transcript(utteranceID: "00-01", text: unicode, isFinal: false))
        XCTAssertEqual(event(GladiaFrames.transcript(unicode, id: nil, isFinal: true)),
                       .transcript(utteranceID: nil, text: unicode, isFinal: true))
        let binary = Data(GladiaFrames.transcript("Hi", id: "7", isFinal: true).utf8)
        XCTAssertEqual(GladiaLiveProtocol.event(from: .binary(binary)),
                       .transcript(utteranceID: "7", text: "Hi", isFinal: true))
        // JSON's own backslash-u escape for U+00E9, built from scalars so no
        // editor can normalise it into the literal character.
        let escaped = "caf" + String(UnicodeScalar(0x5C)) + "u00e9"
        XCTAssertFalse(escaped.contains("\u{E9}"))
        let escapedFrame = #"{"type":"transcript","data":{"id":"1","is_final":true,"#
            + #""utterance":{"text":"\#(escaped)"}}}"#
        XCTAssertEqual(event(escapedFrame), .transcript(utteranceID: "1", text: "caf\u{E9}", isFinal: true))
        XCTAssertEqual(event(GladiaFrames.startSession), .sessionStarted)
        XCTAssertEqual(event(GladiaFrames.endSession), .sessionEnded)
        XCTAssertEqual(event(#"{"type":"error","error":{"message":"Session expired"}}"#), .failure("Session expired"))
        XCTAssertEqual(event(#"{"type":"error","message":"Bad audio"}"#), .failure("Bad audio"))
        XCTAssertEqual(event(#"{"type":"audio_chunk","acknowledged":false,"error":{"exception":"Rejected"}}"#),
                       .failure("Rejected"))
        for ignored in [
            GladiaFrames.endRecording, #"{"type":"speech_start","data":{"time":1.2,"channel":0}}"#,
            #"{"type":"audio_chunk","acknowledged":true,"error":null,"data":{"byte_range":[0,3200]}}"#,
            #"{"type":"translation","error":{"message":"add-on failed"}}"#,
            #"{"type":"post_final_transcript","data":{}}"#, #"{"type":"something_new"}"#, "not json",
            #"{"type":"transcript","data":{"id":"1","is_final":true}}"#
        ] {
            XCTAssertNil(event(ignored), ignored)
        }
    }

    func testErrorDescriptionsNeverCarryTheSessionToken() {
        let errors: [GladiaStreamingError] = [
            .invalidSampleRate(22_050), .invalidPCM, .sessionRequestFailed,
            .sessionRejected(statusCode: 422, message: "Invalid"), .sessionRejected(statusCode: 500, message: nil),
            .invalidSessionResponse, .untrustedSessionURL, .sessionNotReady, .connectionLost,
            .server(message: "Failure"), .unexpectedSessionEnd, .missingCompletion
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("token"), text)
            XCTAssertFalse(text.contains("wss://"), text)
        }
    }

    func testFinalisationContractUsesOneCanonicalBudget() {
        let client: any FinalizingStreamingTranscriptionClient = GladiaLiveClient(apiKey: "k")
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
        XCTAssertEqual(client.finalisationBudget, GladiaLive.finishBudget)
        XCTAssertEqual(GladiaLive.finishBudget, 5, accuracy: 0.000_1)
        let stages = StreamingSessionReadiness.defaultBudget + GladiaLive.drainAllowance + GladiaLive.finalEventWindow
        XCTAssertEqual(GladiaLive.finishBudget, stages, "One whole bound built from each stage's allowance")
        let capabilities = ModelCatalog.liveCapabilities(for: "gladia/solaria-1-streaming")
        XCTAssertEqual(capabilities.postStopFinalizeBudget, GladiaLive.finalEventWindow)
        XCTAssertEqual(capabilities.postStopFinalizeBudget, 1.5)
        XCTAssertFalse(capabilities.supportsLanguageHint, "The canonical capability is unchanged")
        XCTAssertEqual(capabilities.supportedSpeedModes, [.instant, .livePolish])
    }

    func testTheExistingPublicInitializerIsRetained() {
        let initializer: (String, String, String?, Int, URLSession) -> GladiaLiveClient =
            GladiaLiveClient.init(apiKey:model:language:sampleRate:session:)
        let client = initializer("k", "solaria-1", "en_GB", 16_000, .shared)
        XCTAssertEqual(client.model, "solaria-1")
        XCTAssertEqual(client.endpoint.absoluteString, "https://api.gladia.io/v2/live")
        XCTAssertEqual(GladiaLiveClient(apiKey: "k").sampleRate, 16_000)
        XCTAssertEqual(client.currentStage, .idle, "Constructing a client opens nothing")
    }

    private func event(_ text: String) -> GladiaLiveEvent? { GladiaLiveProtocol.event(from: .text(text)) }

    private func rejection(_ status: Int, _ body: String, _ endpoint: URL) -> Error? {
        if case .failure(let error) = GladiaLiveProtocol.sessionURL(statusCode: status, body: Data(body.utf8),
                                                                    endpoint: endpoint) {
            return error
        }
        return nil
    }
}
