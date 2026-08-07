import Foundation
import XCTest

@testable import SpeakApp

/// Routing tests that used to live in OpenRouterAPIClientTests before the
/// client itself moved to SpeakCore. They cover the macOS provider registry's
/// handling of OpenRouter-hosted models.
@MainActor
final class OpenRouterModelRoutingTests: XCTestCase {
  func testProviderRegistryWithOpenRouterOpenAIModel_DoesNotClaimDedicatedProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(
      forModel: "openai/gpt-4o-audio-preview-2024-12-17"
    )

    XCTAssertNil(provider)
  }

  func testProviderRegistryWithDedicatedOpenAIWhisperModel_ReturnsOpenAIProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "openai/whisper-1")

    XCTAssertEqual(provider?.metadata.id, "openai")
  }
}
