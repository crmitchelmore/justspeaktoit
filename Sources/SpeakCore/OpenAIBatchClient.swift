import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "openai",
    displayName: "OpenAI",
    systemImage: "brain.head.profile",
    tintColor: "green",
    website: "https://platform.openai.com"
  )

  private let baseURL: URL
  private let session: URLSession
  private let staging: SharedMultipartUploadStaging?
  private let validationServiceName: String
  private let durationResolver: @Sendable (URL) async -> TimeInterval

  public init(
    session: URLSession = .shared,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    validationServiceName: String = "OpenAI",
    staging: SharedMultipartUploadStaging? = nil,
    durationResolver: @escaping @Sendable (URL) async -> TimeInterval = { _ in 0 }
  ) {
    self.session = session
    self.staging = staging
    self.baseURL = baseURL
    self.validationServiceName = validationServiceName
    self.durationResolver = durationResolver
  }

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let modelName = model.split(separator: "/").last.map(String.init) ?? model
    var fields = [
      OpenAICompatibleBatchTranscriptionClient.FormField(name: "model", value: modelName),
      .init(name: "response_format", value: responseFormat(for: modelName))
    ]
    if requiresChunkingStrategy(modelName) { fields.append(.init(name: "chunking_strategy", value: "auto")) }
    if let language {
      fields.append(.init(name: OpenAITranscriptionModels.batchLanguageFieldName(for: modelName),
                          value: language.localeLanguageCode))
    }
    let (data, _) = try await OpenAICompatibleBatchTranscriptionClient(
      session: session, sharedStaging: try BatchUploadStaging.resolve(staging)
    ).upload(
      request: request, fields: fields,
      file: .init(fieldName: "file", filename: url.lastPathComponent,
                  mimeType: Self.audioMIMEType(for: url), sourceURL: url),
      providerID: metadata.id
    )

    let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
    return try await buildTranscriptionResult(
      response: decoded,
      audioURL: url,
      model: model,
      payload: data
    )
  }

  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await GETProbeAPIKeyValidator(
      url: baseURL.appendingPathComponent("models"),
      headers: { ["Authorization": "Bearer \($0)"] },
      serviceName: validationServiceName,
      session: session
    ).validate(key)
  }

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscription.filter {
        OpenAITranscriptionModels.directBatchModelIDs.contains($0.id)
    }
  }

  private static func audioMIMEType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "wav": return "audio/wav"
    case "mp3": return "audio/mpeg"
    case "flac": return "audio/flac"
    case "ogg", "oga": return "audio/ogg"
    case "webm": return "audio/webm"
    default: return "audio/m4a"
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
    let duration: TimeInterval
    if let reported = response.duration, reported.isFinite, reported > 0 {
      duration = reported
    } else if let end = response.segments?.last?.end, end.isFinite, end > 0 {
      duration = end
    } else {
      duration = await durationResolver(audioURL)
    }
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
