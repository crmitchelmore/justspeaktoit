import SpeakCore
import Foundation

/// Reads transcription-provider API keys from the app's secure storage.
struct TranscriptionProviderCredentials {
  let secureStorage: SecureAppStorage

  /// Reads the provider API key, mapping only a genuine "not found" to
  /// `apiKeyMissing`. Other keychain failures (locked keychain, denied access,
  /// unexpected status) are rethrown as-is so users aren't told to re-enter a
  /// key that exists.
  func apiKey(for metadata: TranscriptionProviderMetadata) async throws -> String {
    do {
      return try await secureStorage.secret(identifier: metadata.apiKeyIdentifier)
    } catch SecureAppStorageError.valueNotFound {
      throw TranscriptionProviderError.apiKeyMissing
    }
  }

  func hasAPIKey(for metadata: TranscriptionProviderMetadata) async -> Bool {
    await secureStorage.hasSecret(identifier: metadata.apiKeyIdentifier)
  }
}
