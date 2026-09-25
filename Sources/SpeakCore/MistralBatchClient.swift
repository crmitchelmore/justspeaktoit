import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MistralBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "mistral",
    displayName: "Mistral",
    systemImage: "waveform.circle",
    tintColor: "indigo",
    website: "https://console.mistral.ai"
  )

  private let baseURL: URL
  private let session: URLSession
  private let multipartStaging: SharedMultipartUploadStaging
  private let durationResolver: @Sendable (URL) async -> TimeInterval

  public init(
    session: URLSession = .shared,
    baseURL: URL = URL(string: "https://api.mistral.ai/v1")!,
    multipartStaging: SharedMultipartUploadStaging,
    durationResolver: @escaping @Sendable (URL) async -> TimeInterval = { _ in 0 }
  ) {
    self.session = session
    self.baseURL = baseURL
    self.multipartStaging = multipartStaging
    self.durationResolver = durationResolver
  }

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw TranscriptionProviderError.apiKeyMissing
    }

    try Task.checkCancellation()
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

    let modelName = modelID(from: model)
    let uploadBodyURL = try Self.makeMultipartUploadBody(
      sourceURL: url,
      staging: multipartStaging,
      boundary: boundary,
      model: modelName,
      language: languageCode(from: language)
    )
    defer { self.multipartStaging.removeUploadBodyFile(at: uploadBodyURL) }

    let (data, response) = try await session.upload(for: request, fromFile: uploadBodyURL)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let responseBody = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, responseBody)
    }

    let decoded = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: data)
    return try await buildTranscriptionResult(response: decoded, audioURL: url, model: model, payload: data)
  }

  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await GETProbeAPIKeyValidator(
      url: baseURL.appendingPathComponent("models"),
      headers: { ["Authorization": "Bearer \($0)"] },
      serviceName: "Mistral",
      session: session
    ).validate(key)
  }

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }

  private func modelID(from model: String) -> String {
    model.split(separator: "/").last.map(String.init) ?? model
  }

  private func languageCode(from language: String?) -> String? {
    guard let language else { return nil }
    let normalized = language
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
    guard let code = normalized.split(separator: "-").first, !code.isEmpty else { return nil }
    return String(code).lowercased()
  }

  public nonisolated static func makeMultipartUploadBody(
    sourceURL: URL,
    staging: SharedMultipartUploadStaging,
    boundary: String,
    model: String,
    language: String?
  ) throws -> URL {
    var fields = [(name: "model", value: model)]
    if let language { fields.append((name: "language", value: language)) }
    let mimeType = sourceURL.pathExtension.lowercased() == "m4a"
      ? "audio/m4a" : BatchTranscriptionJob.mimeType(for: sourceURL) ?? "audio/m4a"
    return try staging.writeMultipart(
      sourceURL: sourceURL, providerID: "mistral", boundary: boundary, fields: fields, mimeType: mimeType
    )
  }

  private func buildTranscriptionResult(
    response: MistralTranscriptionResponse,
    audioURL: URL,
    model: String,
    payload: Data
  ) async throws -> TranscriptionResult {
    let duration: TimeInterval
    if let reported = response.duration, reported > 0 {
      duration = reported
    } else if let segmentEnd = response.lastSegmentEnd, segmentEnd > 0 {
      duration = segmentEnd
    } else {
      duration = await durationResolver(audioURL)
    }
    let transcriptText = response.transcriptText
    let mappedSegments = response.transcriptionSegments(duration: duration)
    let segments = mappedSegments.isEmpty
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

private struct MistralTranscriptionResponse: Decodable {
  struct Segment: Decodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String?
    let speaker: MistralSpeaker?
  }

  struct Word: Decodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
  }

  let text: String?
  let transcription: String?
  let language: String?
  let duration: TimeInterval?
  let segments: [Segment]?
  let words: [Word]?

  var transcriptText: String {
    if shouldLabelSpeakers {
      return segments?.compactMap(segmentText(for:)).joined(separator: "\n") ?? ""
    }
    if let text, !text.isEmpty { return text }
    if let transcription, !transcription.isEmpty { return transcription }
    if let segmentText = segments?.compactMap(\.text).joined(separator: " "), !segmentText.isEmpty {
      return segmentText
    }
    return words?.map(\.text).joined(separator: " ") ?? ""
  }

  var lastSegmentEnd: TimeInterval? {
    let segmentEnd = segments?.compactMap(\.end).max()
    let wordEnd = words?.compactMap(\.end).max()
    return [segmentEnd, wordEnd].compactMap { $0 }.max()
  }

  func transcriptionSegments(duration: TimeInterval) -> [TranscriptionSegment] {
    if let segmentValues = segments?.compactMap({ segment -> TranscriptionSegment? in
      guard let text = segmentText(for: segment), !text.isEmpty else { return nil }
      let start = segment.start ?? 0
      return TranscriptionSegment(
        startTime: start,
        endTime: segment.end ?? max(start, duration),
        text: text
      )
    }), !segmentValues.isEmpty {
      return segmentValues
    }

    return words?.map { word in
      let start = word.start ?? 0
      return TranscriptionSegment(
        startTime: start,
        endTime: word.end ?? start,
        text: word.text
      )
    } ?? []
  }

  private var shouldLabelSpeakers: Bool {
    segments?.contains { $0.speaker?.label != nil } == true
  }

  private func segmentText(for segment: Segment) -> String? {
    guard let text = segment.text else { return nil }
    guard shouldLabelSpeakers, let label = segment.speaker?.label else { return text }
    return "\(label): \(text)"
  }
}

private enum MistralSpeaker: Decodable {
  case int(Int)
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int.self) {
      self = .int(value)
      return
    }
    self = .string(try container.decode(String.self))
  }

  var label: String? {
    switch self {
    case .int(let value):
      return "Speaker \(value + 1)"
    case .string(let value):
      return SpeakerLabelNormalizer.displayLabel(for: value, spacedFormIsIndexed: false)
    }
  }
}
