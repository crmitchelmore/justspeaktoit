import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AssemblyAIBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "assemblyai",
    displayName: "AssemblyAI",
    systemImage: "waveform.badge.mic",
    tintColor: "blue",
    website: "https://assemblyai.com"
  )

  private let baseURL = URL(string: "https://api.assemblyai.com/v2")!
  private let session: URLSession

  private let durationResolver: @Sendable (URL) async throws -> TimeInterval
  var pollingDelay: Duration = .seconds(1)
  var maximumPollingAttempts = 120

  public init(
    session: URLSession = .shared,
    durationResolver: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 0 }
  ) {
    self.session = session
    self.durationResolver = durationResolver
  }

  // MARK: - Batch Transcription

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
    try Task.checkCancellation()
    // Step 1: Upload audio file
    let audioURL = try await uploadAudio(at: url, apiKey: apiKey)

    // Step 2: Submit transcription request
    let transcriptID = try await submitTranscription(
      audioURL: audioURL,
      apiKey: apiKey,
      model: model,
      language: language
    )

    // Step 3: Poll until complete
    let response = try await pollForCompletion(transcriptID: transcriptID, apiKey: apiKey)

    // Step 4: Build result
    try Task.checkCancellation()
    let duration = try await durationResolver(url)
    return buildTranscriptionResult(response: response, duration: duration, model: model)
  }

  private func uploadAudio(at fileURL: URL, apiKey: String) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("upload")

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    // The wire body remains the original encoded file. Foundation streams it
    // directly, avoiding a second recording-sized allocation on either platform.
    let (data, response) = try await session.upload(
      for: request, fromFile: fileURL, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
    )
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw TranscriptionProviderError.httpError(code, body)
    }

    let decoded = try JSONDecoder().decode(AssemblyAIUploadResponse.self, from: data)
    return decoded.uploadURL
  }

  private func submitTranscription(
    audioURL: String,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("transcript")

    var body: [String: Any] = [
      "audio_url": audioURL
    ]

    // Map model identifier to speech_models array
    let speechModels = mapSpeechModels(from: model)
    if !speechModels.isEmpty {
      body["speech_models"] = speechModels
    }

    if let language {
      body["language_code"] = language.localeLanguageCode
    } else {
      body["language_detection"] = true
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(
      for: request, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
    )
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let responseBody = String(data: data, encoding: .utf8) ?? "<no-body>"
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw TranscriptionProviderError.httpError(code, responseBody)
    }

    let decoded = try JSONDecoder().decode(AssemblyAITranscriptStatus.self, from: data)
    return decoded.id
  }

  private func pollForCompletion(
    transcriptID: String,
    apiKey: String
  ) async throws -> AssemblyAITranscriptResult {
    let endpoint = baseURL.appendingPathComponent("transcript/\(transcriptID)")

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

    // Preserve the existing 120-second polling budget and remote retention
    // policy. Cancelling stops local work; it does not delete a remote transcript.
    guard maximumPollingAttempts > 0 else {
      throw TranscriptionProviderError.httpError(408, "Transcription timed out after 120 seconds")
    }
    for _ in 0..<maximumPollingAttempts {
      try Task.checkCancellation()
      try await Task.sleep(for: pollingDelay)

      let (data, response) = try await session.data(
        for: request, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
      )
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        continue
      }

      let status = try JSONDecoder().decode(AssemblyAITranscriptStatus.self, from: data)
      switch status.status {
      case "completed":
        return try JSONDecoder().decode(AssemblyAITranscriptResult.self, from: data)
      case "error":
        throw TranscriptionProviderError.httpError(
          500, status.error ?? "Unknown transcription error")
      default:
        continue  // queued or processing
      }
    }

    throw TranscriptionProviderError.httpError(408, "Transcription timed out after 120 seconds")
  }

  private func buildTranscriptionResult(
    response: AssemblyAITranscriptResult,
    duration: TimeInterval,
    model: String
  ) -> TranscriptionResult {
    let text = response.text ?? ""
    let segments: [TranscriptionSegment]

    if let words = response.words, !words.isEmpty {
      segments = words.map { word in
        TranscriptionSegment(
          startTime: TimeInterval(word.start) / 1000.0,
          endTime: TimeInterval(word.end) / 1000.0,
          text: word.text
        )
      }
    } else {
      segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]
    }

    return TranscriptionResult(
      text: text,
      segments: segments,
      confidence: response.confidence,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  // MARK: - API Key Validation

  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    // Use the /v2/transcript endpoint with a lightweight GET, limited to 1 result,
    // just to validate auth.
    let url = baseURL.appendingPathComponent("transcript")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "limit", value: "1")]

    return await GETProbeAPIKeyValidator(
      url: components.url ?? url,
      headers: { ["Authorization": $0] },
      serviceName: "AssemblyAI",
      session: session
    ).validate(key)
  }

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  // MARK: - Supported Models

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }

  public func mapSpeechModels(from model: String) -> [String] {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    let cleaned = name.replacingOccurrences(of: "-streaming", with: "")
    switch cleaned {
    case AssemblyAIModels.universal35ProAPIName, "universal-3-pro":
      return [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
    case AssemblyAIModels.universal2APIName:
      return [AssemblyAIModels.universal2APIName]
    default:
      return [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
    }
  }

}

// MARK: - Batch Response Models

private struct AssemblyAIUploadResponse: Decodable {
  let uploadURL: String

  private enum CodingKeys: String, CodingKey {
    case uploadURL = "upload_url"
  }
}

private struct AssemblyAITranscriptStatus: Decodable {
  let id: String
  let status: String
  let error: String?
}

private struct AssemblyAITranscriptResult: Decodable {
  let id: String
  let status: String
  let text: String?
  let confidence: Double?
  let words: [AssemblyAIBatchWord]?
  let audioDuration: Double?

  private enum CodingKeys: String, CodingKey {
    case id, status, text, confidence, words
    case audioDuration = "audio_duration"
  }
}

private struct AssemblyAIBatchWord: Decodable {
  let text: String
  let start: Int
  let end: Int
  let confidence: Double?
}
