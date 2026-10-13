import SpeakCore
import XCTest
@testable import SpeakApp

final class FileSpeechIntegrationTests: XCTestCase {
    func testRegistryOwnsEveryNewRouteWithoutOpenRouterFallback() async throws {
        for provider in FileSpeechProvider.allCases {
            let registered = await TranscriptionProviderRegistry.shared.provider(forModel: provider.modelID)
            XCTAssertEqual(registered?.metadata.apiKeyIdentifier, provider.metadata.apiKeyIdentifier)
            XCTAssertTrue(registered is FileSpeechBatchClient)
            XCTAssertTrue(
                ConfigTransferManager.transferableSecretIdentifiers.contains(provider.metadata.apiKeyIdentifier)
            )
        }
        let live = await TranscriptionProviderRegistry.shared.provider(forModel: FileSpeechProvider.reson8LiveID)
        XCTAssertEqual(live?.metadata.id, "reson8")
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: FileSpeechProvider.reson8LiveID))
        XCTAssertTrue(LiveTranscriptionClientFactory.makeClient(for: route, apiKey: "synthetic", language: nil)
                      is Reson8LiveClient)
    }
}
