import XCTest

@testable import SpeakCore

/// Catches "added to the live catalogue, forgot the factory case".
final class ProviderCatalogueCoverageTests: XCTestCase {
    /// Live providers deliberately served by a platform transcriber rather than
    /// the shared factory. Apple is on-device; OpenAI keeps its platform capture
    /// adapters until #1111's capture parity is demonstrated (see #1113).
    private let nativeLiveProviders: Set<LiveTranscriptionProviderID> = [.apple, .openai]

    func testEveryCataloguedLiveModel_hasASharedClientUnlessDeliberatelyNative() throws {
        for model in ModelCatalog.liveTranscription {
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: model.id), model.id)
            let client = LiveTranscriptionClientFactory.makeClient(
                for: route, apiKey: "inert", language: nil, options: LiveClientOptions(keywords: []),
                azureEndpoint: "https://example.invalid"
            )
            if nativeLiveProviders.contains(route.provider) {
                XCTAssertNil(client, model.id)
            } else {
                XCTAssertNotNil(client, "add a factory case for " + model.id)
                XCTAssertEqual(route.sampleRate, route.provider.expectedSampleRate, model.id)
                XCTAssertNotNil(route.apiKeyIdentifier, model.id)
            }
        }
    }
}
