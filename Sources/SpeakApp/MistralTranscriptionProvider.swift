import AVFoundation
import Foundation
import SpeakCore

struct MistralTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "mistral",
    displayName: "Mistral",
    systemImage: "waveform.circle",
    tintColor: "indigo",
    website: "https://console.mistral.ai"
  )

  private let baseURL: URL
  private let session: URLSession
  private let multipartDirectory: URL

  init(
    session: URLSession = .shared,
    baseURL: URL = URL(string: "https://api.mistral.ai/v1")!,
    multipartDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.session = session
    self.baseURL = baseURL
    self.multipartDirectory = multipartDirectory
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw TranscriptionProviderError.apiKeyMissing
    }

    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

    let modelName = modelID(from: model)
    let uploadBodyURL = try Self.makeMultipartUploadBody(
      sourceURL: url,
      destinationDirectory: multipartDirectory,
      boundary: boundary,
      model: modelName,
      language: languageCode(from: language)
    )
    defer { try? FileManager.default.removeItem(at: uploadBodyURL) }

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
        return .success(message: "Mistral API key validated", debug: debug)
      }

      return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
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
        id: "mistral/voxtral-mini-latest",
        displayName: "Voxtral Mini Latest",
        description: "Mistral Voxtral Mini batch transcription for long-form multilingual audio.",
        estimatedLatencyMs: 900,
        latencyTier: .fast
      )
    ]
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

  nonisolated static func makeMultipartUploadBody(
    sourceURL: URL,
    destinationDirectory: URL,
    boundary: String,
    model: String,
    language: String?
  ) throws -> URL {
    let destinationURL = destinationDirectory
      .appendingPathComponent("mistral-upload-\(UUID().uuidString).multipart")
    try FileManager.default.createDirectory(
      at: destinationDirectory,
      withIntermediateDirectories: true
    )

    do {
      guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      let output = try FileHandle(forWritingTo: destinationURL)
      defer { try? output.close() }

      try output.write(contentsOf: Data(Self.formField(named: "model", value: model, boundary: boundary).utf8))
      if let language {
        try output.write(
          contentsOf: Data(Self.formField(named: "language", value: language, boundary: boundary).utf8)
        )
      }
      let fileHeader =
        "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"\(sourceURL.lastPathComponent)\"\r\n"
        + "Content-Type: audio/m4a\r\n\r\n"
      try output.write(contentsOf: Data(fileHeader.utf8))

      let input = try FileHandle(forReadingFrom: sourceURL)
      defer { try? input.close() }
      while true {
        let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
        guard !chunk.isEmpty else { break }
        try output.write(contentsOf: chunk)
      }
      try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
      return destinationURL
    } catch {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }
  }

  private nonisolated static func formField(
    named name: String,
    value: String,
    boundary: String
  ) -> String {
    "--\(boundary)\r\n"
      + "Content-Disposition: form-data; name=\"\(name)\"\r\n"
      + "\r\n"
      + "\(value)\r\n"
  }

  private func buildTranscriptionResult(
    response: MistralTranscriptionResponse,
    audioURL: URL,
    model: String,
    payload: Data
  ) async throws -> TranscriptionResult {
    let duration = await resolvedDuration(for: audioURL, response: response)
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

  private func resolvedDuration(for audioURL: URL, response: MistralTranscriptionResponse) async -> TimeInterval {
    if let duration = response.duration, duration > 0 {
      return duration
    }
    if let lastSegmentEnd = response.lastSegmentEnd, lastSegmentEnd > 0 {
      return lastSegmentEnd
    }
    let asset = AVURLAsset(url: audioURL)
    guard let durationTime = try? await asset.load(.duration), durationTime.seconds.isFinite else {
      return 0
    }
    return durationTime.seconds
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
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let uppercased = trimmed.uppercased()
      if uppercased.hasPrefix("SPEAKER_") {
        let digits = trimmed.filter(\.isNumber)
        if let index = Int(digits) {
          return "Speaker \(index + 1)"
        }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
      } else if uppercased.hasPrefix("SPEAKER ") {
        return trimmed.capitalized
      }
      return trimmed
    }
  }
}
