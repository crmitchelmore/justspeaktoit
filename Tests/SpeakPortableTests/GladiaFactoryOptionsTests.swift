import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Actual factory construction is pure here: no client is started, so no
/// URLSession/default credential/provider boundary is invoked.
final class GladiaFactoryOptionsTests: XCTestCase {
    func testOriginalFactoryOverloadsNowSelectConfiguredGladiaWithoutChangingSignatures() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming"))
        let original: (LiveTranscriptionRoute, String, String?, [String]) -> StreamingTranscriptionClient? =
            LiveTranscriptionClientFactory.makeClient
        let azureCompatible: (
            LiveTranscriptionRoute, String, String?, [String], String
        ) -> StreamingTranscriptionClient? = LiveTranscriptionClientFactory.makeClient
        for made in [original(route, "synthetic", nil, []), azureCompatible(route, "synthetic", "en_GB", [], "")] {
            let client = try XCTUnwrap(made as? GladiaLiveClient)
            XCTAssertEqual(client.finalisationBudget, 4.5)
            XCTAssertTrue(client.usesCheckedDefaultScheduler)
            XCTAssertEqual(client.currentStage, .idle)
        }
        XCTAssertEqual(GladiaLiveClient(apiKey: "synthetic").finalisationBudget, GladiaLive.finishBudget)
    }

    func testActualFactoryCapturesCustomOptionsAndRefusesUnrepresentableTiming() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming"))
        struct Case { let grace: Double; let window: Double; let expected: Double? }
        let cases = [
            Case(grace: 2, window: 3, expected: 8), Case(grace: -1, window: -1, expected: 3),
            Case(grace: .nan, window: .infinity, expected: 4.5), Case(grace: 5e9, window: 5e9, expected: nil)
        ]
        for value in cases {
            let client = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
                for: route, apiKey: "synthetic", language: nil,
                options: LiveClientOptions(
                    keywords: [], assemblyAIKeyterms: [], modulate: .none,
                    postStopFinalizeBudget: value.window, stopGracePeriod: value.grace
                )
            ) as? GladiaLiveClient)
            XCTAssertEqual(client.finalisationBudget, value.expected)
        }
    }

    func testNativeTransportOptionsOverloadSelectsCanonicalCheckedSchedulerWithoutStartingIO() {
        let client = GladiaLiveClient(
            apiKey: "synthetic", options: LiveClientOptions(),
            initiateSession: { _, _ in XCTFail("Construction must not initiate HTTP"); return NeverSessionRequest() },
            makeConnection: { _ in XCTFail("Construction must not create a socket"); return NeverSocket() }
        )
        XCTAssertTrue(client.usesCheckedDefaultScheduler)
        XCTAssertEqual(client.finalisationBudget, 4.5)
        XCTAssertEqual(client.currentStage, .idle)
    }
}

private final class NeverSessionRequest: GladiaLiveSessionRequest {
    func cancel() {}
}
private final class NeverSocket: StreamingWebSocketConnection {
    func resume(onOpen: @escaping @Sendable () -> Void) { XCTFail("Unexpected socket resume") }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {}
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {}
    func cancel() {}
}
