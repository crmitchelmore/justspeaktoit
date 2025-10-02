import Foundation

// MARK: - Provider Protocol

protocol TranscriptionProvider: Sendable {
  var metadata: TranscriptionProviderMetadata { get }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult
  func requiresAPIKey(for model: String) -> Bool
  func supportedModels() -> [ModelCatalog.Option]
}

// MARK: - Provider Metadata

struct TranscriptionProviderMetadata: Sendable, Identifiable {
  let id: String
  let displayName: String
  let apiKeyIdentifier: String
  let apiKeyLabel: String
  let systemImage: String
  let tintColor: String // Color name for UI
  let website: String

  init(
    id: String,
    displayName: String,
    systemImage: String = "network",
    tintColor: String = "blue",
    website: String = ""
  ) {
    self.id = id
    self.displayName = displayName
    self.apiKeyIdentifier = "\(id).apiKey"
    self.apiKeyLabel = "\(displayName) API Key"
    self.systemImage = systemImage
    self.tintColor = tintColor
    self.website = website
  }
}

// MARK: - Provider Registry

actor TranscriptionProviderRegistry {
  static let shared = TranscriptionProviderRegistry()

  private var providers: [String: any TranscriptionProvider] = [:]

  private init() {
    // Register all providers here - adding a new provider automatically makes it available
    providers["openai"] = OpenAITranscriptionProvider()
    providers["revai"] = RevAITranscriptionProvider()
  }

  func allProviders() -> [TranscriptionProviderMetadata] {
    providers.values.map { $0.metadata }.sorted { $0.displayName < $1.displayName }
  }

  func provider(withID id: String) -> (any TranscriptionProvider)? {
    providers[id]
  }

  func provider(forModel model: String) -> (any TranscriptionProvider)? {
    // Extract provider ID from model string (e.g., "openai/whisper-1" -> "openai")
    let components = model.split(separator: "/")
    guard let providerID = components.first else { return nil }
    return providers[String(providerID)]
  }

  func allSupportedModels() -> [ModelCatalog.Option] {
    providers.values.flatMap { $0.supportedModels() }
  }

  func requiresAPIKey(for model: String) -> Bool {
    guard let provider = provider(forModel: model) else { return false }
    return provider.requiresAPIKey(for: model)
  }
}
