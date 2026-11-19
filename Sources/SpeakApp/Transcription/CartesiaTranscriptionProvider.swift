import Foundation
import SpeakCore

enum CartesiaLiveError: LocalizedError {
  case batchNotSupported

  var errorDescription: String? {
    switch self {
    case .batchNotSupported:
      return "Cartesia Ink-2 is currently only available for live streaming in Speak."
    }
  }
}

struct CartesiaTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "cartesia",
    displayName: "Cartesia",
    systemImage: "waveform.and.person.filled",
    tintColor: "purple",
    website: "https://cartesia.ai"
  )

  private let session: URLSession
  private let validationBaseURL = URL(string: "https://api.cartesia.ai")!

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    guard model.trimmingCharacters(in: .whitespacesAndNewlines) == CartesiaBatchClient.catalogID else {
      throw CartesiaLiveError.batchNotSupported
    }
    return try await CartesiaBatchClient(session: session).transcribeFile(
      at: url, apiKey: apiKey, language: language
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    let url = validationBaseURL.appendingPathComponent("voices")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    request.setValue(CartesiaLiveClient.apiVersion, forHTTPHeaderField: "Cartesia-Version")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
      switch http.statusCode {
      case 200..<300:
        return .success(message: "Cartesia API key validated", debug: debug)
      case 401, 403:
        return .failure(message: "Cartesia rejected the key (HTTP \(http.statusCode))", debug: debug)
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
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }
}
