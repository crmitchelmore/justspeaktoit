import Foundation
import SpeakCore

extension OpenRouterAPIClient {
  /// Creates the shared SpeakCore OpenRouter client backed by the macOS
  /// keychain-based secure storage. The API key is resolved lazily on each
  /// request so key changes take effect without recreating the client.
  init(
    secureStorage: SecureAppStorage,
    session: URLSession = .shared,
    apiKeyOverride: String? = nil,
    apiKeyIdentifier: String = "openrouter.apiKey",
    maximumInlineAudioBytes: Int64 = 50 * 1024 * 1024
  ) {
    self.init(
      apiKeyProvider: { try? await secureStorage.secret(identifier: apiKeyIdentifier) },
      session: session,
      apiKeyOverride: apiKeyOverride,
      maximumInlineAudioBytes: maximumInlineAudioBytes
    )
  }
}
