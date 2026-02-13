import AVFoundation
import Foundation
import os.log
import SpeakCore

// MARK: - AssemblyAI Live Transcriber

/// Handles real-time audio streaming to AssemblyAI's v3 WebSocket API.
final class AssemblyAILiveTranscriber: @unchecked Sendable {
  private let apiKey: String
  private let sampleRate: Int
  private var unfairLock = os_unfair_lock()
  private var webSocketTask: URLSessionWebSocketTask?
  private let session: URLSession
  private let bufferPool: AudioBufferPool
  private let logger = Logger(subsystem: "com.speak.app", category: "AssemblyAILiveTranscriber")

  private var onTranscript: ((AssemblyAITurnResponse) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping: Bool = false

  private var keyterms: [String]
  private var language: String?

  init(
    apiKey: String,
    sampleRate: Int = 16000,
    keyterms: [String] = [],
    language: String? = nil,
    session: URLSession = .shared,
    bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
  ) {
    self.apiKey = apiKey
    self.sampleRate = sampleRate
    self.keyterms = keyterms
    self.language = language
    self.session = session
    self.bufferPool = bufferPool
  }

  func start(
    onTranscript: @escaping (AssemblyAITurnResponse) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    isStopping = false
    self.onTranscript = onTranscript
    self.onError = onError

    let isEnglish = language == nil || language?.hasPrefix("en") == true
    let speechModel = isEnglish ? "universal-streaming-english" : "universal-streaming-multi"

    var urlComponents = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
    urlComponents.queryItems = [
      URLQueryItem(name: "sample_rate", value: String(sampleRate)),
      URLQueryItem(name: "encoding", value: "pcm_s16le"),
      URLQueryItem(name: "format_turns", value: "true"),
      URLQueryItem(name: "speech_model", value: speechModel),
      URLQueryItem(name: "min_end_of_turn_silence_when_confident", value: "560"),
    ]

    // AssemblyAI streaming v3 only supports keyterms_prompt (not arbitrary prompts).
    // The preprocessing prompt is applied post-transcription; only keyterms are sent to the WebSocket.
    let validTerms = keyterms.filter { !$0.isEmpty && $0.count <= 50 }.prefix(100)
    for term in validTerms {
      urlComponents.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: term))
    }

    guard let url = urlComponents.url else {
      onError(AssemblyAIError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

    webSocketTask = session.webSocketTask(with: request)
    webSocketTask?.resume()

    logger.info("AssemblyAI WebSocket connecting to \(url.absoluteString.prefix(120))")
    receiveMessages()
  }

  func sendAudio(_ audioData: Data) {
    guard let webSocketTask, webSocketTask.state == .running else { return }

    var buffer = bufferPool.checkout()
    buffer.append(audioData)

    let dataToSend = buffer
    let message = URLSessionWebSocketTask.Message.data(dataToSend)

    webSocketTask.send(message) { [weak self] error in
      guard let self else { return }
      var returnBuffer = buffer
      self.bufferPool.returnBuffer(&returnBuffer)

      if let error {
        if self.isStopping || self.shouldIgnoreSocketError(error) { return }
        self.logger.error("Failed to send audio: \(error.localizedDescription)")
        self.onError?(error)
      }
    }
  }

  func sendAudio(from pcmBuffer: AVAudioPCMBuffer) {
    guard let channelData = pcmBuffer.floatChannelData else { return }

    let frameLength = Int(pcmBuffer.frameLength)
    var buffer = bufferPool.checkout()
    buffer.reserveCapacity(frameLength * 2)

    for i in 0..<frameLength {
      let sample = channelData[0][i]
      let clampedSample = max(-1.0, min(1.0, sample))
      let int16Sample = Int16(clampedSample * Float(Int16.max))
      withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
        buffer.append(contentsOf: bytes)
      }
    }

    guard let webSocketTask, webSocketTask.state == .running else {
      bufferPool.returnBuffer(&buffer)
      return
    }

    let dataToSend = buffer
    let message = URLSessionWebSocketTask.Message.data(dataToSend)

    webSocketTask.send(message) { [weak self] error in
      guard let self else { return }
      var returnBuffer = buffer
      self.bufferPool.returnBuffer(&returnBuffer)

      if let error {
        if self.isStopping || self.shouldIgnoreSocketError(error) { return }
        self.logger.error("Failed to send audio: \(error.localizedDescription)")
        self.onError?(error)
      }
    }
  }

  func stop() {
    guard !isStopping else { return }
    isStopping = true
    bufferPool.logMetrics()

    guard let webSocketTask, webSocketTask.state == .running else {
      self.webSocketTask = nil
      return
    }

    // Capture strong reference so Terminate is always sent even if transcriber is deallocated
    let task = webSocketTask

    // Send ForceEndpoint to flush the current turn before terminating
    let forceMsg = #"{"type":"ForceEndpoint"}"#
    task.send(.string(forceMsg)) { [weak self] _ in
      // Wait long enough for the final Turn response to arrive before terminating
      DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
        let terminateMsg = #"{"type":"Terminate"}"#
        task.send(.string(terminateMsg)) { _ in }
        task.cancel(with: .normalClosure, reason: nil)
        self?.webSocketTask = nil
        self?.logger.info("AssemblyAI WebSocket connection closed")
      }
    }
  }

  func updateConfiguration(_ config: [String: Any]) {
    guard let webSocketTask, webSocketTask.state == .running else { return }
    var payload = config
    payload["type"] = "UpdateConfiguration"
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return }
    webSocketTask.send(.string(json)) { [weak self] error in
      if let error {
        self?.logger.error("Failed to send config update: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Private

  private func shouldIgnoreSocketError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
    if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
      return true
    }
    return false
  }

  private func receiveMessages() {
    os_unfair_lock_lock(&unfairLock)
    let task = webSocketTask
    let stopping = isStopping
    let errorHandler = onError
    os_unfair_lock_unlock(&unfairLock)

    task?.receive { [weak self] result in
      guard let self else { return }

      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveMessages()
      case .failure(let error):
        if stopping || self.shouldIgnoreSocketError(error) { return }
        self.logger.error("WebSocket receive error: \(error.localizedDescription)")
        errorHandler?(error)
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .string(let text):
      parseResponse(text)
    case .data(let data):
      if let text = String(data: data, encoding: .utf8) {
        parseResponse(text)
      }
    @unknown default:
      break
    }
  }

  private func parseResponse(_ json: String) {
    logger.debug("Received AssemblyAI response (length: \(json.count))")
    guard let data = json.data(using: .utf8) else { return }

    do {
      let envelope = try JSONDecoder().decode(AssemblyAIStreamEnvelope.self, from: data)
      switch envelope.type {
      case "Turn":
        let turn = try JSONDecoder().decode(AssemblyAITurnResponse.self, from: data)
        onTranscript?(turn)
      case "Begin":
        logger.info("AssemblyAI session started — \(json.prefix(200))")
      case "Termination":
        logger.info("AssemblyAI session terminated by server")
      default:
        logger.debug("Unhandled AssemblyAI message type: \(envelope.type)")
      }
    } catch {
      logger.debug("Failed to parse AssemblyAI response: \(error.localizedDescription)")
    }
  }
}

// MARK: - AssemblyAI Transcription Provider

struct AssemblyAITranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "assemblyai",
    displayName: "AssemblyAI",
    systemImage: "waveform.badge.mic",
    tintColor: "blue",
    website: "https://assemblyai.com"
  )

  private let baseURL = URL(string: "https://api.assemblyai.com/v2")!
  private let session: URLSession
  private let bufferPool: AudioBufferPool

  init(session: URLSession = .shared, bufferPool: AudioBufferPool? = nil) {
    self.session = session
    self.bufferPool = bufferPool ?? AudioBufferPool(poolSize: 10, bufferSize: 8192)
  }

  // MARK: - Batch Transcription

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
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
    let asset = AVURLAsset(url: url)
    let durationTime = try await asset.load(.duration)
    let duration = durationTime.seconds
    return buildTranscriptionResult(response: response, duration: duration, model: model)
  }

  private func uploadAudio(at fileURL: URL, apiKey: String) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("upload")

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Data(contentsOf: fileURL)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw TranscriptionProviderError.httpError(code, body)
    }

    let decoded = try JSONDecoder().decode(AssemblyAIUploadResponse.self, from: data)
    return decoded.upload_url
  }

  private func submitTranscription(
    audioURL: String,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> String {
    let endpoint = baseURL.appendingPathComponent("transcript")

    var body: [String: Any] = [
      "audio_url": audioURL,
    ]

    // Map model identifier to speech_models array
    let speechModels = mapSpeechModels(from: model)
    if !speechModels.isEmpty {
      body["speech_models"] = speechModels
    }

    if let language {
      let code = extractLanguageCode(from: language)
      body["language_code"] = code
    } else {
      body["language_detection"] = true
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
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

    for _ in 0..<120 {  // Timeout after ~120 seconds
      try await Task.sleep(for: .seconds(1))

      let (data, response) = try await session.data(for: request)
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

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    // Use the /v2/transcript endpoint with a lightweight GET to validate
    let url = baseURL.appendingPathComponent("transcript")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(trimmed, forHTTPHeaderField: "Authorization")
    // Limit to 1 result just to validate auth
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "limit", value: "1")]
    request.url = components.url

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
      }

      let debug = debugSnapshot(request: request, response: http, data: data)

      if (200..<300).contains(http.statusCode) {
        return .success(message: "AssemblyAI API key validated", debug: debug)
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

  // MARK: - Supported Models

  func supportedModels() -> [ModelCatalog.Option] {
    [
      ModelCatalog.Option(
        id: "assemblyai/universal-3-pro",
        displayName: "Universal-3 Pro",
        description: "AssemblyAI's most powerful and accurate speech model."
      ),
      ModelCatalog.Option(
        id: "assemblyai/universal-2",
        displayName: "Universal-2",
        description: "AssemblyAI's previous generation model. Fast and reliable."
      ),
    ]
  }

  /// Creates a live transcriber for streaming audio.
  func createLiveTranscriber(
    apiKey: String,
    sampleRate: Int = 16000,
    keyterms: [String] = [],
    language: String? = nil
  ) -> AssemblyAILiveTranscriber {
    AssemblyAILiveTranscriber(
      apiKey: apiKey,
      sampleRate: sampleRate,
      keyterms: keyterms,
      language: language,
      session: session,
      bufferPool: bufferPool
    )
  }

  // MARK: - Private Helpers

  private func mapSpeechModels(from model: String) -> [String] {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    let cleaned = name.replacingOccurrences(of: "-streaming", with: "")
    switch cleaned {
    case "universal-3-pro":
      return ["universal-3-pro"]
    case "universal-2":
      return ["universal-2"]
    default:
      return ["universal-3-pro", "universal-2"]
    }
  }

  private func extractLanguageCode(from locale: String) -> String {
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

// MARK: - Streaming Response Models

private struct AssemblyAIStreamEnvelope: Decodable {
  let type: String
}

struct AssemblyAITurnResponse: Decodable {
  let type: String
  let turn_order: Int
  let turn_is_formatted: Bool
  let end_of_turn: Bool
  let transcript: String
  let end_of_turn_confidence: Double?
  let words: [AssemblyAIStreamWord]?
  let utterance: String?
  let language_code: String?
  let language_confidence: Double?
}

struct AssemblyAIStreamWord: Decodable {
  let text: String
  let word_is_final: Bool
  let start: Int
  let end: Int
  let confidence: Double?
}

// MARK: - Batch Response Models

private struct AssemblyAIUploadResponse: Decodable {
  let upload_url: String
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
  let audio_duration: Double?
}

private struct AssemblyAIBatchWord: Decodable {
  let text: String
  let start: Int
  let end: Int
  let confidence: Double?
}

// MARK: - Error Types

enum AssemblyAIError: LocalizedError {
  case invalidURL
  case connectionFailed
  case sendFailed
  case missingAPIKey

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Failed to construct AssemblyAI WebSocket URL"
    case .connectionFailed:
      return "Failed to establish WebSocket connection to AssemblyAI"
    case .sendFailed:
      return "Failed to send audio data to AssemblyAI"
    case .missingAPIKey:
      return "AssemblyAI API key is missing. Please configure it in Settings."
    }
  }
}
