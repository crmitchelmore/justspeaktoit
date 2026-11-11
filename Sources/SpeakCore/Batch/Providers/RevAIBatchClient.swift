import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RevAIBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "revai",
    displayName: "Rev.ai",
    systemImage: "waveform.badge.mic",
    tintColor: "purple",
    website: "https://www.rev.ai"
  )

  private let baseURL = URL(string: "https://api.rev.ai/speechtotext/v1")!
  private let session: URLSession
  private let multipartStaging: SharedMultipartUploadStaging
  private let durationResolver: @Sendable (URL) async throws -> TimeInterval
  var pollingDelay: Duration = .seconds(2)
  var maximumPollingAttempts = 150

  public init(
    session: URLSession = .shared,
    multipartStaging: SharedMultipartUploadStaging,
    durationResolver: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 0 }
  ) {
    self.session = session
    self.multipartStaging = multipartStaging
    self.durationResolver = durationResolver
  }

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
    try Task.checkCancellation()
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

  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await GETProbeAPIKeyValidator(
      url: baseURL.appendingPathComponent("jobs"),
      headers: { ["Authorization": "Bearer \($0)"] },
      serviceName: "Rev.ai",
      session: session
    ).validate(key)
  }

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }

  // MARK: - Private Methods

  private func submitJob(url: URL, apiKey: String, language: String?) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("jobs")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Add metadata
    var metadata: [String: Any] = [:]
    if let language {
      // Rev.ai accepts language codes like "en", but also accepts locale-specific codes
      // Normalize to just language code for consistency
      metadata["language"] = language.localeLanguageCode
    }
    metadata["skip_diarization"] = false
    metadata["skip_punctuation"] = false

    let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
    let body = try multipartStaging.writeMultipart(
      sourceURL: url, providerID: self.metadata.id, boundary: boundary,
      fields: [(name: "metadata", value: String(data: metadataJSON, encoding: .utf8) ?? "{}")],
      mimeType: url.pathExtension.lowercased() == "m4a"
        ? "audio/m4a" : BatchTranscriptionJob.mimeType(for: url) ?? "audio/m4a",
      fileField: "media"
    )
    defer { multipartStaging.removeUploadBodyFile(at: body) }
    let (data, response) = try await session.upload(for: request, fromFile: body)
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

  private func pollForCompletion(jobID: String, apiKey: String) async throws -> RevAITranscriptResponse {
    let endpoint = baseURL.appendingPathComponent("jobs/\(jobID)")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Poll every 2 seconds for up to 5 minutes
    guard maximumPollingAttempts > 0 else {
      throw TranscriptionProviderError.httpError(408, "Rev.ai transcription timed out")
    }
    for _ in 0..<maximumPollingAttempts {
      try Task.checkCancellation()
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
        try await Task.sleep(for: pollingDelay)
      }
    }

    throw TranscriptionProviderError.httpError(408, "Rev.ai transcription timed out")
  }

  private func fetchTranscript(jobID: String, apiKey: String) async throws -> RevAITranscriptResponse {
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
    let duration = try await durationResolver(audioURL)

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
              startTime: element.startTime ?? 0,
              endTime: element.endTime ?? 0,
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

}

// MARK: - Response Models

private struct RevAIJobResponse: Decodable {
  let id: String
  let status: String
}

private struct RevAITranscriptResponse: Decodable {
  struct Monologue: Decodable {
    let speaker: Int?
    let elements: [RevAITranscriptElement]
  }
  let monologues: [Monologue]?
}

private struct RevAITranscriptElement: Decodable {
  let type: String
  let value: String?
  let startTime: TimeInterval?
  let endTime: TimeInterval?
  let confidence: Double?

  private enum CodingKeys: String, CodingKey {
    case type, value, confidence
    case startTime = "ts"
    case endTime = "end_ts"
  }
}
