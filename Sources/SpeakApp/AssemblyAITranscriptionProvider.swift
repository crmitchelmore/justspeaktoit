import AVFoundation
import Foundation
import SpeakCore

struct AssemblyAITranscriptionProvider: TranscriptionProvider {
  private let client: AssemblyAIBatchClient
  var metadata: TranscriptionProviderMetadata { client.metadata }

  init(session: URLSession = .shared) {
    client = AssemblyAIBatchClient(session: session, durationResolver: { url in
      let asset = AVURLAsset(url: url)
      return try await asset.load(.duration).seconds
    })
  }

  func transcribeFile(
    at url: URL, apiKey: String, model: String, language: String?
  ) async throws -> TranscriptionResult {
    try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
  func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
  func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }
  func mapSpeechModels(from model: String) -> [String] { client.mapSpeechModels(from: model) }

}
