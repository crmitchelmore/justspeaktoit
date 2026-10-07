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

    /// One request for every client of the stream: the handshake the shared
    /// client opens is the public builder the macOS controller uses, with the
    /// trimmed key as a bearer token (the documented server scheme and the
    /// official SDKs' header) and the pinned version in the header and query.
    func testEveryClientOpensTheOneCanonicalRequest() throws {
        let fixture = CartesiaLiveFixture(key: "synthetic-key")
        fixture.start()
        defer { fixture.client.cancel() }
        let opened = try XCTUnwrap(fixture.factory.requests.first)
        let canonical = try XCTUnwrap(CartesiaLiveClient.webSocketRequest(
            apiKey: " synthetic-key \n", model: "ink-2", sampleRate: 16_000
        ))
        XCTAssertEqual(canonical.url, opened.url)
        XCTAssertEqual(canonical.url, CartesiaLiveClient.webSocketURL(model: "ink-2", sampleRate: 16_000))
        XCTAssertEqual(canonical.allHTTPHeaderFields?.count, 2)
        for field in ["Authorization", "Cartesia-Version"] {
            XCTAssertEqual(canonical.value(forHTTPHeaderField: field), opened.value(forHTTPHeaderField: field), field)
        }
        XCTAssertEqual(canonical.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertNil(canonical.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(CartesiaLiveClient.apiVersion, "2026-03-01", "Cartesia keeps a pinned version's contract")
        XCTAssertEqual(canonical.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaLiveClient.apiVersion)
        let query = URLComponents(url: try XCTUnwrap(canonical.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "cartesia_version" }?.value, CartesiaLiveClient.apiVersion)
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

    func testErrorFramesKeepTheProviderStatusAndMessage() {
        func failure(_ object: [String: Any]) -> NSError? {
            let json = CartesiaTestSocket.eventJSON(object)
            guard case .failure(let failure)? = CartesiaTurnEvent(data: Data(json.utf8)) else { return nil }
            let error = CartesiaLiveProtocol.error(for: failure) as NSError
            XCTAssertEqual(CartesiaLiveClient.providerError(from: json) as NSError?, error)
            return error
        }
        for status in [401, 403] {
            let error = failure(["type": "error", "status_code": status, "title": "Unauthorized", "message": "No"])
            XCTAssertEqual(error?.domain, "Cartesia")
            XCTAssertEqual(error?.code, status)
            XCTAssertEqual(error?.localizedDescription, "No")
        }
        let invalidModel = failure([
            "type": "error", "status_code": 400, "title": "Invalid model",
            "message": "The model is not valid.", "error_code": "model_not_found"
        ])
        XCTAssertEqual(invalidModel?.code, 400)
        XCTAssertEqual(invalidModel?.localizedDescription, "The model is not valid.")
        let titled = failure(["type": "error", "status_code": 500, "title": "Server error"])
        XCTAssertEqual(titled?.code, 500)
        XCTAssertEqual(titled?.localizedDescription, "Server error")
        let untitled = failure(["type": "error"])
        XCTAssertEqual(untitled?.code, -1)
        XCTAssertEqual(untitled?.localizedDescription, "Cartesia streaming error")
        let noisy = "line one\nline two " + String(repeating: "x", count: 400)
        let message = failure(["type": "error", "status_code": 500, "message": noisy])?.localizedDescription ?? ""
        XCTAssertFalse(message.contains("\n"))
        XCTAssertLessThanOrEqual(message.count, 201)
        XCTAssertNil(CartesiaLiveClient.providerError(from: #"{"type":"turn.end","transcript":"Not an error."}"#))
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
        // The drain bound, then the catalogue's post-stop budget after `close`.
        let postStop = ModelCatalog.liveCapabilities(for: "cartesia/ink-2-streaming").postStopFinalizeBudget
        XCTAssertEqual(finalizing.finalisationBudget, CartesiaLiveClient.finishBudget + postStop)
        XCTAssertEqual(CartesiaLiveClient.finishBudget, 1.5)
        let widened = CartesiaLiveClient(
            apiKey: "k", postStopFinalizeBudget: 4, stopGracePeriod: 0.5, makeConnection: { _ in CartesiaTestSocket() }
        )
        XCTAssertEqual(widened.finalisationBudget, CartesiaLiveClient.finishBudget + 4.5)
    }

    func testBudgetsAreBounded() {
        XCTAssertEqual(CartesiaLiveClient.readyDeadline, 10)
        XCTAssertEqual(CartesiaLiveClient.sendDeadline, 5)
        // Two seconds of 16 kHz PCM16 mono: twenty 100 ms frames.
        XCTAssertEqual(CartesiaLiveRun(sampleRate: 16_000).maximumBytes, 64_000)
        // The host watchdog keeps its 10 s floor with the default budget.
        XCTAssertLessThanOrEqual((CartesiaLiveClient(apiKey: "k").finalisationBudget ?? .infinity) + 1, 10)
    }
}
