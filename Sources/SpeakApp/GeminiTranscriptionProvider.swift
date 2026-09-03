import AVFoundation
import Foundation
import SpeakCore

// MARK: - Gemini 3.5 Transcribe (prerecorded)
//
// Google's Interactions API, not `generateContent`:
//   POST https://generativelanguage.googleapis.com/v1beta/interactions
//   x-goog-api-key: <key>
// Docs: https://ai.google.dev/gemini-api/docs/transcribe
//       https://ai.google.dev/gemini-api/docs/interactions/audio
//       https://ai.google.dev/gemini-api/docs/files

enum GeminiBatchError: LocalizedError, Equatable {
  case missingAPIKey
  case unsupportedModel(String)
  case rateLimited(String)
  case uploadFailed(String)
  case emptyTranscript

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Google Gemini API key is missing. Please add it in Settings → Google Gemini."
    case .unsupportedModel(let model):
      return "\(model) is not a Google Gemini transcription model."
    case .rateLimited(let message):
      return "Google Gemini rate limit reached: \(message)"
    case .uploadFailed(let message):
      return "Uploading the recording to Google Gemini failed: \(message)"
    case .emptyTranscript:
      return "Google Gemini returned no transcript for this recording."
    }
  }
}

/// Batch file transcription with `gemini-3.5-transcribe` over the Interactions
/// API.
///
/// Recordings small enough for the API's 20 MB request cap are sent inline as
/// base64; larger ones go through the Files API first. Word-level timestamps
/// and speaker diarization are requested in verbatim mode, which is why the
/// upstream limit is 30 minutes of audio rather than the unannotated 1 hour.
///
/// Never logs audio, transcript text or the API key.
struct GeminiTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "google",
    displayName: GeminiTranscribeModels.providerDisplayName,
    systemImage: "sparkles",
    tintColor: "blue",
    website: "https://aistudio.google.com/apikey"
  )

  private let session: URLSession
  private let inlineAudioByteLimit: Int
  private let filePollInterval: TimeInterval
  private let filePollTimeout: TimeInterval

  init(
    session: URLSession = .shared,
    inlineAudioByteLimit: Int = GeminiTranscribeModels.inlineAudioByteLimit,
    filePollInterval: TimeInterval = 1.5,
    filePollTimeout: TimeInterval = 60
  ) {
    self.session = session
    self.inlineAudioByteLimit = inlineAudioByteLimit
    self.filePollInterval = filePollInterval
    self.filePollTimeout = filePollTimeout
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else { throw GeminiBatchError.missingAPIKey }
    guard GeminiTranscribeModels.directBatchModelIDs.contains(model) else {
      throw GeminiBatchError.unsupportedModel(model)
    }

    let mimeType = GeminiAudioMIMEType.forFile(at: url)
    let source = try await self.audioSource(for: url, mimeType: mimeType, apiKey: trimmedKey)
    let request = try GeminiInteractionsRequest.make(
      apiKey: trimmedKey,
      model: GeminiTranscribeModels.batchAPIName,
      audio: source,
      mimeType: mimeType,
      language: language
    )
    let (data, response) = try await self.session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw GeminiInteractionsResponse.mapHTTPFailure(status: http.statusCode, body: data)
    }

    let decoded = try JSONDecoder().decode(GeminiInteractionsResponse.self, from: data)
    let transcript = decoded.transcript
    guard !transcript.isEmpty else { throw GeminiBatchError.emptyTranscript }

    let duration = await Self.assetDuration(for: url)
    return TranscriptionResult(
      text: transcript,
      segments: Self.segments(from: decoded, transcript: transcript, duration: duration),
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      // `TranscriptionSegment` has no speaker field yet, so the `spk_N` labels
      // Gemini returns alongside each word survive only here. Typed speaker
      // metadata is the follow-up tracked in issue #816.
      rawPayload: String(data: data, encoding: .utf8),
      debugInfo: nil
    )
  }

  /// Small recordings go inline; anything above the Interactions API's request
  /// cap is uploaded through the Files API first.
  private func audioSource(
    for url: URL,
    mimeType: String,
    apiKey: String
  ) async throws -> GeminiAudioSource {
    let audioData = try Data(contentsOf: url)
    guard audioData.count > self.inlineAudioByteLimit else {
      return .inline(audioData)
    }
    return .fileURI(
      try await self.uploadFile(
        data: audioData,
        mimeType: mimeType,
        apiKey: apiKey,
        displayName: url.lastPathComponent
      )
    )
  }

  /// One segment per annotated word, or a single whole-recording segment when
  /// the response carries no word annotations.
  private static func segments(
    from response: GeminiInteractionsResponse,
    transcript: String,
    duration: TimeInterval
  ) -> [TranscriptionSegment] {
    let words = response.wordAnnotations
    guard !words.isEmpty else {
      return [TranscriptionSegment(startTime: 0, endTime: duration, text: transcript)]
    }
    return words.map {
      TranscriptionSegment(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
    }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    var request = URLRequest(url: GeminiTranscribeModels.listModelsURL)
    request.httpMethod = "GET"
    request.setValue(trimmed, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)

    do {
      let (data, response) = try await self.session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      switch http.statusCode {
      case 200..<300:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http)
        return .success(message: "Google Gemini API key validated", debug: debug)
      case 401, 403:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(
          message: "Google Gemini rejected the key (HTTP \(http.statusCode))", debug: debug)
      case 429:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "Google Gemini rate limit reached (HTTP 429)", debug: debug)
      default:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
      }
    } catch {
      return .failure(message: "Validation failed: \(error.localizedDescription)")
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  /// Only Google's own transcription model. The `google/gemini-2.0-flash-*`
  /// entries share this prefix but are OpenRouter-routed, so a prefix match
  /// would steal them from the OpenRouter batch client.
  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscription.filter {
      GeminiTranscribeModels.directBatchModelIDs.contains($0.id)
    }
  }

  // MARK: - Files API

  /// Resumable upload used when the recording is too large to inline. Returns
  /// the `file.uri` the Interactions request references.
  private func uploadFile(
    data: Data,
    mimeType: String,
    apiKey: String,
    displayName: String
  ) async throws -> String {
    var start = URLRequest(url: GeminiTranscribeModels.fileUploadURL)
    start.httpMethod = "POST"
    start.setValue(apiKey, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)
    start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
    start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
    start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
    start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.httpBody = try JSONSerialization.data(
      withJSONObject: ["file": ["display_name": displayName]]
    )

    let (startBody, startResponse) = try await self.session.data(for: start)
    guard let startHTTP = startResponse as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }
    guard (200..<300).contains(startHTTP.statusCode) else {
      throw GeminiInteractionsResponse.mapHTTPFailure(status: startHTTP.statusCode, body: startBody)
    }
    guard
      let uploadURLString = startHTTP.value(forHTTPHeaderField: "x-goog-upload-url"),
      let uploadURL = URL(string: uploadURLString)
    else {
      throw GeminiBatchError.uploadFailed("The upload session URL was missing.")
    }

    var upload = URLRequest(url: uploadURL)
    upload.httpMethod = "POST"
    upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
    upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
    upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
    upload.httpBody = data

    let (uploadBody, uploadResponse) = try await self.session.data(for: upload)
    guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }
    guard (200..<300).contains(uploadHTTP.statusCode) else {
      throw GeminiInteractionsResponse.mapHTTPFailure(status: uploadHTTP.statusCode, body: uploadBody)
    }
    guard let file = try? JSONDecoder().decode(GeminiFileUploadResponse.self, from: uploadBody),
      let uploaded = file.file, uploaded.uri != nil
    else {
      throw GeminiBatchError.uploadFailed("The upload response did not contain a file URI.")
    }
    return try await self.activeFileURI(for: uploaded, apiKey: apiKey)
  }

  /// A freshly uploaded file starts in `PROCESSING`; referencing its URI before
  /// the Files API reports `ACTIVE` fails the Interactions request. Polls the
  /// file resource until it is usable, or gives up inside a bounded budget.
  private func activeFileURI(
    for file: GeminiUploadedFile,
    apiKey: String
  ) async throws -> String {
    guard let uri = file.uri else {
      throw GeminiBatchError.uploadFailed("The upload response did not contain a file URI.")
    }
    switch file.state?.uppercased() {
    case "ACTIVE":
      return uri
    case "FAILED":
      throw GeminiBatchError.uploadFailed("Google could not process the uploaded recording.")
    default:
      break
    }
    guard let name = file.name,
      let statusURL = GeminiTranscribeModels.fileStatusURL(name: name)
    else {
      throw GeminiBatchError.uploadFailed("The upload response did not name the uploaded file.")
    }

    let deadline = Date().addingTimeInterval(self.filePollTimeout)
    while Date() < deadline {
      try await Task.sleep(nanoseconds: UInt64(max(0, self.filePollInterval) * 1_000_000_000))
      switch try await self.fileState(at: statusURL, apiKey: apiKey)?.uppercased() {
      case "ACTIVE":
        return uri
      case "FAILED":
        throw GeminiBatchError.uploadFailed("Google could not process the uploaded recording.")
      default:
        continue
      }
    }
    throw GeminiBatchError.uploadFailed(
      "The uploaded recording was still processing after \(Int(self.filePollTimeout)) seconds.")
  }

  private func fileState(at url: URL, apiKey: String) async throws -> String? {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)

    let (data, response) = try await self.session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw GeminiInteractionsResponse.mapHTTPFailure(status: http.statusCode, body: data)
    }
    let decoder = JSONDecoder()
    // The status endpoint answers with the File resource itself; the upload
    // endpoint wraps it in `{"file": …}`. Accept either spelling.
    if let file = try? decoder.decode(GeminiUploadedFile.self, from: data), file.state != nil {
      return file.state
    }
    return (try? decoder.decode(GeminiFileUploadResponse.self, from: data))?.file?.state
  }

  private static func assetDuration(for url: URL) async -> TimeInterval {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return 0 }
    let seconds = duration.seconds
    return seconds.isFinite ? seconds : 0
  }
}
