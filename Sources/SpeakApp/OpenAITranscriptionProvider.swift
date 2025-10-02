import AVFoundation
import Foundation

struct OpenAITranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "openai",
    displayName: "OpenAI",
    systemImage: "brain.head.profile",
    tintColor: "green",
    website: "https://platform.openai.com"
  )

  private let baseURL = URL(string: "https://api.openai.com/v1")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let audioData = try Data(contentsOf: url)
    var body = Data()

    // Extract model name without provider prefix
    let modelName = model.split(separator: "/").last.map(String.init) ?? model

    body.appendFormField(named: "model", value: modelName, boundary: boundary)
    body.appendFormField(named: "response_format", value: "verbose_json", boundary: boundary)

    if let language {
      // OpenAI expects ISO-639-1 (2-letter code), not full locale (e.g., "en" not "en_GB")
      let languageCode = extractLanguageCode(from: language)
      body.appendFormField(named: "language", value: languageCode, boundary: boundary)
    }

    body.appendFileField(
      named: "file",
      filename: url.lastPathComponent,
      mimeType: "audio/m4a",
      fileData: audioData,
      boundary: boundary
    )
    body.appendString("--\(boundary)--\r\n")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, body)
    }

    let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
    return try await buildTranscriptionResult(
      response: decoded,
      audioURL: url,
      model: model,
      payload: data
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    let url = baseURL.appendingPathComponent("models")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
      }

      let debug = debugSnapshot(request: request, response: http, data: data)

      if (200..<300).contains(http.statusCode) {
        return .success(message: "OpenAI API key validated", debug: debug)
      }

      let message = "HTTP \(http.statusCode) while validating key"
      return .failure(message: message, debug: debug)
    } catch {
      return .failure(
        message: "Validation failed: \(error.localizedDescription)",
        debug: debugSnapshot(request: request, error: error)
      )
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    [
      ModelCatalog.Option(
        id: "openai/whisper-1",
        displayName: "Whisper",
        description: "OpenAI's speech recognition model. Fast and accurate."
      )
    ]
  }

  private func extractLanguageCode(from locale: String) -> String {
    // Extract just the language code from locale identifiers
    // e.g., "en_GB" -> "en", "en-US" -> "en", "en" -> "en"
    let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
    return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
  }

  private func buildTranscriptionResult(
    response: OpenAITranscriptionResponse,
    audioURL: URL,
    model: String,
    payload: Data
  ) async throws -> TranscriptionResult {
    let asset = AVURLAsset(url: audioURL)
    let durationTime = try await asset.load(.duration)
    let duration = durationTime.seconds

    let segments =
      response.segments?.map { segment in
        TranscriptionSegment(
          startTime: segment.start,
          endTime: segment.end,
          text: segment.text
        )
      } ?? [TranscriptionSegment(startTime: 0, endTime: duration, text: response.text)]

    return TranscriptionResult(
      text: response.text,
      segments: segments,
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: String(data: payload, encoding: .utf8),
      debugInfo: nil
    )
  }

  private func debugSnapshot(
    request: URLRequest,
    response: HTTPURLResponse? = nil,
    data: Data? = nil,
    error: Error? = nil
  ) -> APIKeyValidationDebugSnapshot {
    APIKeyValidationDebugSnapshot(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "GET",
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
      statusCode: response?.statusCode,
      responseHeaders: response.map { headers in
        headers.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
          guard let key = entry.key as? String else { return }
          partialResult[key] = String(describing: entry.value)
        }
      } ?? [:],
      responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
      errorDescription: error?.localizedDescription
    )
  }
}

// MARK: - Response Models

private struct OpenAITranscriptionResponse: Decodable {
  struct Segment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  let text: String
  let language: String?
  let duration: TimeInterval?
  let segments: [Segment]?
}

// MARK: - Error Types

enum TranscriptionProviderError: LocalizedError {
  case invalidResponse
  case httpError(Int, String)
  case apiKeyMissing

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The server returned an invalid response."
    case .httpError(let code, let body):
      return "Server responded with status \(code): \(body)"
    case .apiKeyMissing:
      return "API key is required but not provided."
    }
  }
}
