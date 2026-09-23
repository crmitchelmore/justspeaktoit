import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Ink-2 automatic-turns contract as documented at
/// https://docs.cartesia.ai/api-reference/stt/turns/websocket (read 2026-09-22).
final class CartesiaLiveProtocolTests: XCTestCase {
    func testRequestKeepsTheShippingEndpointHeadersAndQuery() throws {
        let fixture = CartesiaLiveFixture(key: " synthetic-key \n")
        fixture.start()
        defer { fixture.client.cancel() }
        let request = try XCTUnwrap(fixture.factory.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://api.cartesia.ai/stt/turns/websocket?model=ink-2&encoding=pcm_s16le&sample_rate=16000"
                + "&cartesia_version=2026-03-01"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-03-01")
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic-key") ?? true, "The key stays in the header")
        let names = Set(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? [])
        // Ink-2's canonical capability takes no language hint; nothing unsupported is sent.
        XCTAssertEqual(names, ["model", "encoding", "sample_rate", "cartesia_version"])
        XCTAssertFalse(ModelCatalog.liveCapabilities(for: "cartesia/ink-2-streaming").supportsLanguageHint)
    }

    func testRouteModelAndRateReachTheQuery() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "cartesia/ink-2-streaming"))
        XCTAssertEqual(route.apiModelName, "ink-2")
        XCTAssertEqual(route.sampleRate, 16_000)
        let url = try XCTUnwrap(CartesiaLiveProtocol.webSocketURL(model: route.apiModelName, sampleRate: 24_000))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, "24000")
        XCTAssertEqual(items.first { $0.name == "model" }?.value, "ink-2")
    }

    func testMissingKeyFailsWithoutOpeningASocket() {
        let fixture = CartesiaLiveFixture(key: "  ")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        guard case .missingAPIKey(let provider)? = fixture.log.errors.first as? StreamingClientError else {
            return XCTFail("Expected a missing key, got \(fixture.log.errors)")
        }
        XCTAssertEqual(provider, "Cartesia")
    }

    func testCloseIsTheDocumentedJSONCommand() throws {
        let data = Data(CartesiaLiveProtocol.closeCommand.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["type": "close"])
    }

    func testDocumentedServerEventsDecode() {
        func decode(_ object: [String: Any]) -> CartesiaTurnEvent? {
            CartesiaTurnEvent(data: Data(CartesiaTestSocket.eventJSON(object).utf8))
        }
        XCTAssertEqual(decode(["type": "connected"]), .connected)
        XCTAssertEqual(decode(["type": "turn.start"]), .turnStart)
        XCTAssertEqual(decode(["type": "turn.update", "transcript": "Hey can you"]), .turnUpdate("Hey can you"))
        XCTAssertEqual(decode(["type": "turn.eager_end", "transcript": "Hey?"]), .turnEagerEnd("Hey?"))
        XCTAssertEqual(decode(["type": "turn.resume"]), .turnResume)
        XCTAssertEqual(decode(["type": "turn.end", "transcript": " Grüße 👋🏽"]), .turnEnd(" Grüße 👋🏽"))
        XCTAssertEqual(decode(["type": "turn.end"]), .turnEnd(""), "A turn boundary without text still ends it")
        // Frames shaped like the earlier integration's are still read; the
        // documented top-level field wins when both are present.
        XCTAssertEqual(
            decode(["type": "turn.update", "results": [["transcript": ""], ["transcript": "book a table"]]]),
            .turnUpdate("book a table")
        )
        XCTAssertEqual(
            decode(["type": "turn.end", "transcript": "Documented.", "results": [["transcript": "legacy"]]]),
            .turnEnd("Documented.")
        )
        XCTAssertNil(decode(["type": "turn.future_event"]))
        XCTAssertNil(CartesiaTurnEvent(data: Data("not json".utf8)))
        XCTAssertNil(CartesiaTurnEvent(data: Data(#"{"transcript":"no type"}"#.utf8)))
    }

    func testEarlierSeamsStaySourceCompatible() {
        XCTAssertEqual(
            CartesiaLiveClient.webSocketURL(model: "ink-2", sampleRate: 16_000),
            CartesiaLiveProtocol.webSocketURL(model: "ink-2", sampleRate: 16_000)
        )
        let update = CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"turn.update","results":[{"transcript":"book a table"}]}"#
        )
        XCTAssertEqual(update?.text, "book a table")
        XCTAssertEqual(update?.isFinal, false)
        let end = CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"turn.end","results":[{"transcript":"book a table for two"}]}"#
        )
        XCTAssertEqual(end?.text, "book a table for two")
        XCTAssertEqual(end?.isFinal, true)
        let documented = CartesiaLiveClient.transcriptEvent(from: #"{"type":"turn.end","transcript":"Done."}"#)
        XCTAssertEqual(documented?.text, "Done.")
        XCTAssertNil(CartesiaLiveClient.transcriptEvent(from: #"{"type":"turn.update","results":[{"transcript":""}]}"#))
        XCTAssertNil(CartesiaLiveClient.transcriptEvent(from: #"{"type":"turn.start"}"#))
    }

    func testErrorFramesMapToTypedFailures() {
        func failure(_ object: [String: Any]) -> Error? {
            guard case .failure(let failure)? = CartesiaTurnEvent(
                data: Data(CartesiaTestSocket.eventJSON(object).utf8)
            ) else { return nil }
            return CartesiaLiveProtocol.error(for: failure)
        }
        for status in [401, 403] {
            let error = failure(["type": "error", "status_code": status, "title": "Unauthorized", "message": "No"])
            guard case .invalidAPIKey(let provider)? = error as? StreamingClientError else {
                return XCTFail("\(status) must be a rejected key")
            }
            XCTAssertEqual(provider, "Cartesia")
        }
        let invalidModel = failure([
            "type": "error", "status_code": 400, "title": "Invalid model",
            "message": "The model is not valid.", "error_code": "model_not_found"
        ])
        XCTAssertEqual(
            invalidModel as? CartesiaStreamingError,
            .server(statusCode: 400, code: "model_not_found", message: "The model is not valid.")
        )
        let titled = failure(["type": "error", "status_code": 500, "title": "Server error"])
        XCTAssertEqual(titled as? CartesiaStreamingError, .server(statusCode: 500, code: nil, message: "Server error"))
        let noisy = "line one\nline two " + String(repeating: "x", count: 400)
        let long = failure(["type": "error", "status_code": 500, "message": noisy])
        guard case .server(_, _, let message)? = long as? CartesiaStreamingError else {
            return XCTFail("Expected a server failure")
        }
        XCTAssertFalse(message.contains("\n"))
        XCTAssertLessThanOrEqual(message.count, 201)
    }

    func testTransportFailuresRecogniseRejectedKeys() {
        let coded = CartesiaLiveProtocol.connectionError(NSError(domain: "WebSocket", code: 401))
        XCTAssertNotNil(coded as? StreamingClientError)
        let described = CartesiaLiveProtocol.connectionError(NSError(
            domain: "WebSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Handshake failed: HTTP 403 Forbidden"]
        ))
        XCTAssertNotNil(described as? StreamingClientError)
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual((CartesiaLiveProtocol.connectionError(lost) as? URLError)?.code, .networkConnectionLost)
    }

    func testPublicContractIsPreservedAndFinalises() {
        // The shipping initializer keeps its exact labels and defaults.
        let shipping: (String, String, Int, URLSession) -> CartesiaLiveClient =
            CartesiaLiveClient.init(apiKey:model:sampleRate:session:)
        let client = shipping("k", "ink-2", 16_000, .shared)
        let defaulted = CartesiaLiveClient(apiKey: "k")
        let finalizing: any FinalizingStreamingTranscriptionClient = defaulted
        XCTAssertEqual(client.finalShape, .standaloneSegments)
        XCTAssertEqual(finalizing.finalShape, .standaloneSegments)
        XCTAssertTrue(finalizing.finishFlushesBufferedAudio)
        XCTAssertEqual(finalizing.finalisationBudget, CartesiaLiveClient.finishBudget)
        XCTAssertEqual(CartesiaLiveClient.finishBudget, 8)
    }

    func testBudgetsAreBoundedAndNestedInsideTheFinish() {
        XCTAssertLessThan(CartesiaLiveClient.finishReadyBudget, CartesiaLiveClient.finishBudget)
        XCTAssertLessThan(CartesiaLiveClient.sendDeadline, CartesiaLiveClient.finishBudget)
        XCTAssertEqual(CartesiaLiveClient.readyDeadline, 10)
        XCTAssertEqual(CartesiaLiveClient.maximumQueuedFrames, 256)
        // Five seconds of 16 kHz PCM16 mono: fifty 100 ms capture frames.
        XCTAssertEqual(CartesiaLiveRun(sampleRate: 16_000).maximumBytes, 160_000)
        // The host watchdog keeps its 10 s floor with this budget.
        XCTAssertLessThanOrEqual(CartesiaLiveClient.finishBudget + 1, 10)
    }
}
