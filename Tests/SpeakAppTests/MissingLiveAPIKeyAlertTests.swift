import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class MissingLiveAPIKeyAlertTests: XCTestCase {
  func testMessage_describesTranscriptionModelWithoutLiveOnlyWording() {
    let provider = TranscriptionProviderMetadata(
      id: "cartesia",
      displayName: "Cartesia",
      website: "https://cartesia.ai"
    )

    let alert = MissingLiveAPIKeyAlert(
      provider: provider,
      modelDisplayName: "Cartesia Ink-2"
    )

    XCTAssertEqual(alert.title, "API key required")
    XCTAssertTrue(alert.message.contains("Cartesia needs an API key for transcription"))
    XCTAssertTrue(alert.message.contains("Cartesia Ink-2"))
    XCTAssertFalse(alert.message.contains("live transcription"))
  }

  func testProviderMetadataAPIKeyURL_usesProviderWebsite() {
    let provider = TranscriptionProviderMetadata(
      id: "cartesia",
      displayName: "Cartesia",
      website: "https://cartesia.ai"
    )

    XCTAssertEqual(provider.apiKeyURL?.absoluteString, "https://cartesia.ai")
  }

  func testProviderMetadataAPIKeyURL_isNilWhenWebsiteMissing() {
    let provider = TranscriptionProviderMetadata(
      id: "custom",
      displayName: "Custom"
    )

    XCTAssertNil(provider.apiKeyURL)
  }
}
