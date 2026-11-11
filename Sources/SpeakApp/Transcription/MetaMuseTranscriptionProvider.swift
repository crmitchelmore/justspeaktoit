import Foundation
import SpeakCore

/// Batch/file transcription through Meta Model API's dedicated speech endpoint.
struct MetaMuseTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: MetaMuseVoiceTranscribe.providerID,
    displayName: "Meta",
    systemImage: "waveform.badge.mic",
    tintColor: "blue",
    website: "https://llama.developer.meta.com"
  )

  private let client: MetaMuseBatchClient
  private let session: URLSession
  private let defaults: UserDefaults

  init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
    client = MetaMuseBatchClient(session: session)
    self.session = session
    self.defaults = defaults
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    try await client.transcribeFile(
      at: url,
      apiKey: apiKey,
      model: model,
      language: language,
      keywords: MetaMuseVoiceTranscribe.keywords(
        from: defaults.string(forKey: "assemblyAIKeyterms") ?? ""
      )
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await MetaMuseAPIKeyValidator(session: session).validate(key)
  }

  func requiresAPIKey(for model: String) -> Bool { true }

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
