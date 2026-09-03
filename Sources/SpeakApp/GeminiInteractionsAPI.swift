import Foundation
import SpeakCore

// MARK: - Gemini Interactions API wire types
//
// Request shaping and response decoding for `POST /v1beta/interactions`, kept
// separate from the provider so every field on the wire is testable without a
// network round trip.
// Docs: https://ai.google.dev/gemini-api/docs/transcribe

// MARK: - Request shaping

/// Where the audio for one interaction comes from.
enum GeminiAudioSource: Equatable {
  case inline(Data)
  case fileURI(String)
}

enum GeminiInteractionsRequest {
  /// Builds the Interactions API request. Pure, so the wire body is asserted in
  /// tests without a network round trip.
  ///
  /// Word timestamps and speaker diarization are only valid in `verbatim` mode
  /// and are mutually exclusive with `custom_vocabulary`, so this request never
  /// sends a vocabulary: the `TranscriptionProvider` protocol carries no keyterm
  /// parameter today, and dropping annotations to gain one would be the worse
  /// trade for recorded audio.
  static func make(
    apiKey: String,
    model: String = GeminiTranscribeModels.batchAPIName,
    audio: GeminiAudioSource,
    mimeType: String,
    language: String?,
    mode: GeminiTranscriptionMode = .verbatim,
    wordTimestamps: Bool = true,
    diarization: Bool = true
  ) throws -> URLRequest {
    var audioInput: [String: Any] = ["type": "audio", "mime_type": mimeType]
    switch audio {
    case .inline(let data):
      audioInput["data"] = data.base64EncodedString()
    case .fileURI(let uri):
      audioInput["uri"] = uri
    }

    var modeValue: Any = mode.batchWireValue
    if mode == .verbatim, wordTimestamps || diarization {
      var verbatim: [String: Any] = ["type": mode.batchWireValue]
      if wordTimestamps { verbatim["timestamp_granularities"] = ["word"] }
      if diarization { verbatim["diarization_mode"] = "speaker" }
      modeValue = verbatim
    }

    let payload: [String: Any] = [
      "model": model,
      "input": [audioInput],
      "generation_config": [
        "transcription_config": [
          "language_codes": GeminiTranscribeModels.languageCodes(from: language),
          "mode": modeValue
        ]
      ]
    ]

    var request = URLRequest(url: GeminiTranscribeModels.interactionsURL)
    request.httpMethod = "POST"
    request.setValue(
      apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: payload, options: [.sortedKeys]
    )
    return request
  }
}

/// Maps a recording's extension onto one of the documented audio MIME types.
enum GeminiAudioMIMEType {
  private static let byExtension: [String: String] = [
    "aac": "audio/aac",
    "aiff": "audio/aiff",
    "flac": "audio/flac",
    "m4a": "audio/m4a",
    "mp3": "audio/mp3",
    "mp4": "audio/m4a",
    "mpeg": "audio/mpeg",
    "ogg": "audio/ogg",
    "opus": "audio/opus",
    "wav": "audio/wav",
    "webm": "audio/webm"
  ]

  static func forFile(at url: URL) -> String {
    byExtension[url.pathExtension.lowercased()] ?? "audio/m4a"
  }
}

// MARK: - Response models

struct GeminiWordAnnotation: Equatable {
  let text: String
  let speaker: String?
  let startTime: TimeInterval
  let endTime: TimeInterval
}

/// One `annotations[]` entry on a model-output content block.
struct GeminiResponseAnnotation: Decodable {
  let type: String?
  let text: String?
  let speaker: String?
  let startOffset: String?
  let endOffset: String?

  private enum CodingKeys: String, CodingKey {
    case type, text, speaker
    case startOffset = "start_offset"
    case endOffset = "end_offset"
  }
}

struct GeminiResponseContent: Decodable {
  let type: String?
  let text: String?
  let annotations: [GeminiResponseAnnotation]?
}

struct GeminiResponseStep: Decodable {
  let type: String?
  let content: [GeminiResponseContent]?
}

struct GeminiInteractionsResponse: Decodable {
  let id: String?
  let status: String?
  let outputText: String?
  let steps: [GeminiResponseStep]?

  private enum CodingKeys: String, CodingKey {
    case id, status, steps
    case outputText = "output_text"
  }

  /// The full transcript: `output_text` when present, otherwise the concatenated
  /// text content of the model-output steps.
  var transcript: String {
    if let outputText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !outputText.isEmpty {
      return outputText
    }
    let parts = (steps ?? [])
      .flatMap { $0.content ?? [] }
      .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return parts.joined(separator: " ")
  }

  /// Word-level timing and speaker attribution, in document order.
  var wordAnnotations: [GeminiWordAnnotation] {
    (steps ?? [])
      .flatMap { $0.content ?? [] }
      .flatMap { $0.annotations ?? [] }
      .compactMap { annotation in
        guard annotation.type == "word_info" else { return nil }
        guard let text = annotation.text, !text.isEmpty else { return nil }
        return GeminiWordAnnotation(
          text: text,
          speaker: annotation.speaker,
          startTime: Self.seconds(from: annotation.startOffset),
          endTime: Self.seconds(from: annotation.endOffset)
        )
      }
  }

  /// Parses the API's duration spelling (`"0.100s"`).
  static func seconds(from offset: String?) -> TimeInterval {
    guard let offset else { return 0 }
    let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
    let numeric = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
    return TimeInterval(numeric) ?? 0
  }

  /// Maps an HTTP failure onto the app's error vocabulary. The body is a Gemini
  /// error envelope: `{"error": {"code": …, "message": …, "status": …}}`.
  static func mapHTTPFailure(status: Int, body: Data) -> Error {
    let envelope = try? JSONDecoder().decode(GeminiRESTErrorEnvelope.self, from: body)
    let message = envelope?.error?.message ?? String(data: body, encoding: .utf8) ?? "<no-body>"
    switch status {
    case 401, 403:
      return StreamingClientError.invalidAPIKey(
        provider: GeminiTranscribeModels.providerDisplayName)
    case 429:
      return GeminiBatchError.rateLimited(message)
    default:
      return TranscriptionProviderError.httpError(status, message)
    }
  }
}

private struct GeminiRESTErrorPayload: Decodable {
  let message: String?
  let status: String?
}

private struct GeminiRESTErrorEnvelope: Decodable {
  let error: GeminiRESTErrorPayload?
}

struct GeminiUploadedFile: Decodable {
  let name: String?
  let uri: String?
  /// `PROCESSING`, `ACTIVE` or `FAILED`. An Interactions request that
  /// references a file before it is `ACTIVE` is rejected, so this is polled.
  let state: String?
}

struct GeminiFileUploadResponse: Decodable {
  let file: GeminiUploadedFile?
}
