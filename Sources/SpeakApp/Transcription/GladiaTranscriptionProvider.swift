import Foundation
import SpeakCore

struct GladiaTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "gladia",
    displayName: "Gladia",
    systemImage: "waveform.badge.sparkles",
    tintColor: "teal",
    website: "https://www.gladia.io"
  )

  private let session: URLSession
  private let baseURL: URL
  private let independentCleanup: Bool

  init(
    session: URLSession = .shared, baseURL: URL = GladiaLive.baseURL,
    independentCleanup: Bool = false
  ) {
    self.session = session
    self.baseURL = baseURL
    self.independentCleanup = independentCleanup
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    guard model.trimmingCharacters(in: .whitespacesAndNewlines) == GladiaBatchClient.catalogID else {
      throw BatchTranscriptionJobError.unsupportedModel("Gladia")
    }
    let client = GladiaBatchClient(session: session, baseURL: baseURL)
    return try await (independentCleanup ? client.withIndependentCleanup() : client).transcribeFile(
      at: url, apiKey: apiKey, model: model, language: language
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    var request = URLRequest(url: baseURL.appendingPathComponent("v2/live"))
    request.httpMethod = "GET"
    request.setValue(trimmed, forHTTPHeaderField: "x-gladia-key")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      switch http.statusCode {
      case 200..<300:
        // The listing body echoes previous sessions' transcripts, so it is deliberately
        // left out of the debug snapshot on success.
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http)
        return .success(message: "Gladia API key validated", debug: debug)
      case 401, 403:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "Gladia rejected the key (HTTP \(http.statusCode))", debug: debug)
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

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
