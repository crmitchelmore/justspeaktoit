import Foundation
import SpeakCore

struct GroqTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "groq",
    displayName: "Groq",
    systemImage: "bolt.horizontal.circle",
    tintColor: "orange",
    website: "https://console.groq.com"
  )

  private let compatibleProvider: OpenAITranscriptionProvider

  init(session: URLSession = .shared) {
    compatibleProvider = OpenAITranscriptionProvider(
      session: session,
      baseURL: URL(string: "https://api.groq.com/openai/v1")!,
      validationServiceName: "Groq"
    )
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    try await compatibleProvider.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await compatibleProvider.validateAPIKey(key)
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
