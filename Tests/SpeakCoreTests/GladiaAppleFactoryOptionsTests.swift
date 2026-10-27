import Foundation
import XCTest
@testable import SpeakCore

/// The native Apple graph includes the shared factory. Construction is pure:
/// no client is started and no credential or provider boundary is invoked.
final class GladiaAppleFactoryOptionsTests: XCTestCase {
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
}
