import SpeakCore
import Foundation

struct OpenAITranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "openai",
    displayName: "OpenAI",
    systemImage: "brain.head.profile",
    tintColor: "green",
    website: "https://platform.openai.com"
  )

  private let baseURL: URL
  private let session: URLSession
  private let validationServiceName: String

  init(
    session: URLSession = .shared,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    validationServiceName: String = "OpenAI"
  ) {
    self.session = session
    self.baseURL = baseURL
    self.validationServiceName = validationServiceName
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
    body.appendFormField(named: "response_format", value: responseFormat(for: modelName), boundary: boundary)
    if requiresChunkingStrategy(modelName) {
      body.appendFormField(named: "chunking_strategy", value: "auto", boundary: boundary)
    }

    if let language {
        // OpenAI expects ISO-639-1 (2-letter code), not full locale (e.g., "en" not "en_GB").
        // The new GPT Transcribe family accepts plural language hints while
        // existing GPT-4o and Whisper models retain the singular field.
        let languageCode = language.localeLanguageCode
        body.appendFormField(
            named: OpenAITranscriptionModels.batchLanguageFieldName(for: modelName),
            value: languageCode,
            boundary: boundary
        )
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
    await GETProbeAPIKeyValidator(
      url: baseURL.appendingPathComponent("models"),
      headers: { ["Authorization": "Bearer \($0)"] },
      serviceName: validationServiceName,
      session: session
    ).validate(key)
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscription.filter {
        OpenAITranscriptionModels.directBatchModelIDs.contains($0.id)
    }
  }

  private func responseFormat(for modelName: String) -> String {
    if modelName == "gpt-4o-transcribe-diarize" {
      return "diarized_json"
    }
    if modelName.hasPrefix("whisper") {
      return "verbose_json"
    }
    return "json"
  }

  private func requiresChunkingStrategy(_ modelName: String) -> Bool {
    modelName == "gpt-4o-transcribe-diarize"
  }

  private func buildTranscriptionResult(
    response: OpenAITranscriptionResponse,
    audioURL: URL,
    model: String,
    payload: Data
  ) async throws -> TranscriptionResult {
    let duration = await resolvedTranscriptionDuration(
      reported: response.duration,
      lastSegmentEnd: response.segments?.last?.end,
      audioURL: audioURL
    )
    let transcriptText = response.transcriptText

    let mappedSegments =
      response.segments?.map { segment in
        TranscriptionSegment(
          startTime: segment.start,
          endTime: segment.end,
          text: response.segmentText(for: segment)
        )
      } ?? []
    let segments =
      mappedSegments.isEmpty
      ? [TranscriptionSegment(startTime: 0, endTime: duration, text: transcriptText)]
      : mappedSegments

    return TranscriptionResult(
      text: transcriptText,
      segments: segments,
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: String(data: payload, encoding: .utf8),
      debugInfo: nil
    )
  }
}

// MARK: - Response Models

private struct OpenAITranscriptionResponse: Decodable {
  struct Segment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String?
  }

  let text: String?
  let language: String?
  let duration: TimeInterval?
  let segments: [Segment]?

  var transcriptText: String {
    if shouldLabelSpeakers {
      return segments?.map(segmentText(for:)).joined(separator: "\n") ?? (text ?? "")
    }
    return text ?? segments?.map(\.text).joined(separator: " ") ?? ""
  }

  func segmentText(for segment: Segment) -> String {
    guard shouldLabelSpeakers, let label = speakerLabel(from: segment.speaker) else {
      return segment.text
    }
    return "\(label): \(segment.text)"
  }

  private var shouldLabelSpeakers: Bool {
    let speakers = Set((segments ?? []).compactMap { speakerLabel(from: $0.speaker) })
    return !speakers.isEmpty
  }

  private func speakerLabel(from value: String?) -> String? {
    SpeakerLabelNormalizer.displayLabel(for: value, spacedFormIsIndexed: true)
  }
}
