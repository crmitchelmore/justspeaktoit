import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class MetaMuseTranscriptionProviderTests: XCTestCase {
  func testRegistryIncludesMetaBatchProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(withID: "meta")

    XCTAssertEqual(provider?.metadata.displayName, "Meta")
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "meta.apiKey")
    XCTAssertEqual(provider?.supportedModels().map(\.id), [MetaMuseVoiceTranscribe.batchCatalogID])
  }
}
