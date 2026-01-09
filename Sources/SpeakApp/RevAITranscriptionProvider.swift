import SpeakCore
import AVFoundation
import Foundation

struct RevAITranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "revai",
    displayName: "Rev.ai",
    systemImage: "waveform.badge.mic",
    tintColor: "purple",
    website: "https://www.rev.ai"
  )

  private let baseURL = URL(string: "https://api.rev.ai/speechtotext/v1")!
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
    // Step 1: Submit job
    let jobID = try await submitJob(url: url, apiKey: apiKey, language: language)

    // Step 2: Poll for completion
    let transcript = try await pollForCompletion(jobID: jobID, apiKey: apiKey)

    // Step 3: Build result
    return try await buildTranscriptionResult(
      transcript: transcript,
      audioURL: url,
      model: model
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    let url = baseURL.appendingPathComponent("jobs")
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
        return .success(message: "Rev.ai API key validated", debug: debug)
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
        id: "revai/default",
        displayName: "Rev.ai",
        description: "Rev.ai's speech recognition. High accuracy with speaker identification."
      )
    ]
  }

  // MARK: - Private Methods

  private func submitJob(url: URL, apiKey: String, language: String?) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("jobs")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let audioData = try Data(contentsOf: url)
    var body = Data()

    // Add metadata
    var metadata: [String: Any] = [:]
    if let language {
      // Rev.ai accepts language codes like "en", but also accepts locale-specific codes
      // Normalize to just language code for consistency
      let languageCode = extractLanguageCode(from: language)
      metadata["language"] = languageCode
    }
    metadata["skip_diarization"] = false
    metadata["skip_punctuation"] = false

    if let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) {
      body.appendFormField(
        named: "metadata",
        value: String(data: metadataJSON, encoding: .utf8) ?? "{}",
        boundary: boundary
      )
    }

    body.appendFileField(
      named: "media",
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

    let decoded = try JSONDecoder().decode(RevAIJobResponse.self, from: data)
    return decoded.id
  }

  private func pollForCompletion(jobID: String, apiKey: String) async throws
    -> RevAITranscriptResponse
  {
    let endpoint = baseURL.appendingPathComponent("jobs/\(jobID)")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Poll every 2 seconds for up to 5 minutes
    for _ in 0..<150 {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TranscriptionProviderError.invalidResponse
      }

      guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<no-body>"
        throw TranscriptionProviderError.httpError(http.statusCode, body)
      }

      let job = try JSONDecoder().decode(RevAIJobResponse.self, from: data)

      switch job.status {
      case "transcribed":
        return try await fetchTranscript(jobID: jobID, apiKey: apiKey)
      case "failed":
        throw TranscriptionProviderError.httpError(500, "Rev.ai transcription failed")
      default:
        // Still processing
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      }
    }

    throw TranscriptionProviderError.httpError(408, "Rev.ai transcription timed out")
  }

  private func fetchTranscript(jobID: String, apiKey: String) async throws
    -> RevAITranscriptResponse
  {
    let endpoint = baseURL.appendingPathComponent("jobs/\(jobID)/transcript")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.rev.transcript.v1.0+json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, body)
    }

    return try JSONDecoder().decode(RevAITranscriptResponse.self, from: data)
  }

  private func buildTranscriptionResult(
    transcript: RevAITranscriptResponse,
    audioURL: URL,
    model: String
  ) async throws -> TranscriptionResult {
    let asset = AVURLAsset(url: audioURL)
    let durationTime = try await asset.load(.duration)
    let duration = durationTime.seconds

    // Build full text from monologues
    let fullText =
      transcript.monologues?
      .flatMap { $0.elements }
      .compactMap { $0.value }
      .joined(separator: " ") ?? ""

    // Build segments from monologues
    var segments: [TranscriptionSegment] = []
    if let monologues = transcript.monologues {
      for monologue in monologues {
        for element in monologue.elements where element.type == "text" {
          segments.append(
            TranscriptionSegment(
              startTime: element.ts ?? 0,
              endTime: element.end_ts ?? 0,
              text: element.value ?? ""
            ))
        }
      }
    }

    if segments.isEmpty {
      segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: fullText)]
    }

    return TranscriptionResult(
      text: fullText,
      segments: segments,
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  private func extractLanguageCode(from locale: String) -> String {
    // Extract just the language code from locale identifiers
    // e.g., "en_GB" -> "en", "en-US" -> "en", "en" -> "en"
    let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
    return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
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

private struct RevAIJobResponse: Decodable {
  let id: String
  let status: String
  let created_on: String?
}

private struct RevAITranscriptResponse: Decodable {
  struct Monologue: Decodable {
    struct Element: Decodable {
      let type: String
      let value: String?
      let ts: TimeInterval?
      let end_ts: TimeInterval?
      let confidence: Double?
    }

    let speaker: Int?
    let elements: [Element]
  }

  let monologues: [Monologue]?
}
