import XCTest

@testable import SpeakApp
import SpeakCore

final class XAITranscriptionProviderTests: XCTestCase {
  func testProviderRegistry_routesGrokVoiceToXAI() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(
      forModel: XAIVoiceModels.thinkFast2CatalogID
    )

    XCTAssertEqual(provider?.metadata.id, "xai")
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "xai.apiKey")
    XCTAssertEqual(provider?.supportedModels().map(\.id), [XAIVoiceModels.thinkFast2CatalogID])
  }
}
