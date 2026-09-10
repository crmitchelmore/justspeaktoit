import Foundation
import SpeakCore

struct XAITranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "xai",
    displayName: "xAI",
    systemImage: "waveform.badge.mic",
    tintColor: "black",
    website: "https://console.x.ai"
  )

  private let session: URLSession
  private let validationURL = URL(string: "https://api.x.ai/v1/models")!

  init(session: URLSession = .shared) {
    self.session = session
  }

  /// File transcription goes to xAI's dedicated speech-to-text endpoint, which
  /// is a different service from the Grok Voice realtime route: Grok Voice has
  /// no file mode, so a request naming it belongs to the streaming picker.
  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard model == XAISpeechToText.batchCatalogID else {
      throw XAITranscriptionProviderError.batchNotSupported(model)
    }
    return try await XAIBatchTranscriptionClient(session: session).transcribeFile(
      at: url,
      apiKey: apiKey,
      language: language
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    var request = URLRequest(url: validationURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response")
      }
      let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
      switch http.statusCode {
      case 200..<300:
        return .success(message: "xAI API key validated", debug: debug)
      case 401, 403:
        return .failure(message: "xAI rejected the key (HTTP \(http.statusCode))", debug: debug)
      default:
        return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
      }
    } catch {
      return .failure(message: "Validation failed: \(error.localizedDescription)")
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  /// Both catalogues: the Grok Voice streaming route and the dedicated
  /// speech-to-text pair. The registry matches a model to its provider through
  /// this list, so a batch identifier that is missing here would fall through
  /// to OpenRouter with the wrong credential.
  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}

enum XAITranscriptionProviderError: LocalizedError {
  case batchNotSupported(String)

  var errorDescription: String? {
    switch self {
    case .batchNotSupported(let model):
      return "\(ModelCatalog.transcriptionDisplayName(for: model, isBatch: false)) has no file "
        + "transcription mode. Choose xAI Speech-to-Text for recordings, or keep this model for "
        + "live streaming."
    }
  }
}
