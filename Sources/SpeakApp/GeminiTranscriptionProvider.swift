import Foundation
import SpeakCore

// MARK: - Gemini 3.5 Transcribe (prerecorded)
//
// The Interactions API client, its request/response models, the resumable
// Files API upload and the ACTIVE-state poll all live in
// `SpeakCore/GeminiInteractionsClient.swift` so iOS uploads through the same
// code (issue #862). What remains here is the macOS `TranscriptionProvider`
// conformance: registry metadata, credential validation and the catalogue
// filter.

/// macOS provider wrapper over the shared `GeminiInteractionsClient`.
///
/// Never logs audio, transcript text or the API key.
struct GeminiTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "google",
    displayName: GeminiTranscribeModels.providerDisplayName,
    systemImage: "sparkles",
    tintColor: "blue",
    website: "https://aistudio.google.com/apikey"
  )

  private let session: URLSession
  private let client: GeminiInteractionsClient

  init(
    session: URLSession = .shared,
    inlineAudioByteLimit: Int = GeminiTranscribeModels.inlineAudioByteLimit,
    filePollInterval: TimeInterval = 1.5,
    filePollTimeout: TimeInterval = 60
  ) {
    self.session = session
    self.client = GeminiInteractionsClient(
      session: session,
      inlineAudioByteLimit: inlineAudioByteLimit,
      filePollInterval: filePollInterval,
      filePollTimeout: filePollTimeout
    )
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    try await self.client.transcribeFile(
      at: url, apiKey: apiKey, model: model, language: language)
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    var request = URLRequest(url: GeminiTranscribeModels.listModelsURL)
    request.httpMethod = "GET"
    request.setValue(trimmed, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)

    do {
      let (data, response) = try await self.session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      switch http.statusCode {
      case 200..<300:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http)
        return .success(message: "Google Gemini API key validated", debug: debug)
      case 401, 403:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(
          message: "Google Gemini rejected the key (HTTP \(http.statusCode))", debug: debug)
      case 429:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "Google Gemini rate limit reached (HTTP 429)", debug: debug)
      default:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
      }
    } catch {
      return .failure(message: "Validation failed: \(error.localizedDescription)")
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  /// Only Google's own transcription model. The `google/gemini-2.0-flash-*`
  /// entries share this prefix but are OpenRouter-routed, so a prefix match
  /// would steal them from the OpenRouter batch client.
  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscription.filter {
      GeminiTranscribeModels.directBatchModelIDs.contains($0.id)
    }
  }
}
