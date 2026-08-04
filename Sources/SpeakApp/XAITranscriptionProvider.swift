import Foundation
import SpeakCore

enum XAITranscriptionProviderError: LocalizedError {
  case batchNotSupported

  var errorDescription: String? {
    switch self {
    case .batchNotSupported:
      return "xAI Grok Voice is currently available as live streaming transcription only."
    }
  }
}

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

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    _ = (url, apiKey, model, language)
    throw XAITranscriptionProviderError.batchNotSupported
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
      let debug = debugSnapshot(request: request, response: http, data: data)
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

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
  }

  private func debugSnapshot(
    request: URLRequest,
    response: HTTPURLResponse,
    data: Data
  ) -> APIKeyValidationDebugSnapshot {
    var requestHeaders = request.allHTTPHeaderFields ?? [:]
    if requestHeaders["Authorization"] != nil {
      requestHeaders["Authorization"] = "Bearer [REDACTED]"
    }
    return APIKeyValidationDebugSnapshot(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "GET",
      requestHeaders: requestHeaders,
      requestBody: nil,
      statusCode: response.statusCode,
      responseHeaders: response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        guard let key = pair.key as? String else { return }
        result[key] = String(describing: pair.value)
      },
      responseBody: String(data: data, encoding: .utf8),
      errorDescription: nil
    )
  }
}
