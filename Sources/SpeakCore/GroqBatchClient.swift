import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GroqBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "groq",
    displayName: "Groq",
    systemImage: "bolt.horizontal.circle",
    tintColor: "orange",
    website: "https://console.groq.com"
  )

  private let compatibleProvider: OpenAIBatchClient

  public init(
    session: URLSession = .shared,
    durationResolver: @escaping @Sendable (URL) async -> TimeInterval = { _ in 0 }
  ) {
    compatibleProvider = OpenAIBatchClient(
      session: session,
      baseURL: URL(string: "https://api.groq.com/openai/v1")!,
      validationServiceName: "Groq",
      durationResolver: durationResolver
    )
  }

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    try await compatibleProvider.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
  }

  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await compatibleProvider.validateAPIKey(key)
  }

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
