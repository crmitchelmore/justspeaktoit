// swiftlint:disable file_length
import Foundation
import os.log
import SpeakCore

// MARK: - Errors

enum SpeechmaticsLiveError: LocalizedError {
  case missingAPIKey
  case invalidURL
  case invalidAPIKey
  case batchNotSupported
  case encodingFailed
  case serverError(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "Speechmatics API key is missing. Please add it in Settings → Speechmatics."
    case .invalidURL:
      "Failed to construct Speechmatics WebSocket URL."
    case .invalidAPIKey:
      "Speechmatics API key is invalid. Check your key in Settings → Speechmatics."
    case .batchNotSupported:
      "Speechmatics is currently only available for live streaming in Speak."
    case .encodingFailed:
      "Failed to encode the Speechmatics realtime request."
    case .serverError(let message):
      "Speechmatics realtime error: \(message)"
    }
  }
}

// MARK: - Provider

struct SpeechmaticsTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "speechmatics",
    displayName: "Speechmatics",
    systemImage: "waveform.and.magnifyingglass",
    tintColor: "cyan",
    website: "https://www.speechmatics.com"
  )

  private let validationURL = URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs")!
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
    throw SpeechmaticsLiveError.batchNotSupported
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    var request = URLRequest(url: validationURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
      }

      let debug = debugSnapshot(request: request, response: http, data: data)
      if (200..<300).contains(http.statusCode) {
        return .success(message: "Speechmatics API key validated", debug: debug)
      }
      if http.statusCode == 401 || http.statusCode == 403 {
        return .failure(message: "Speechmatics rejected the key (HTTP \(http.statusCode))", debug: debug)
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
        id: "speechmatics/enhanced-streaming",
        displayName: "Speechmatics Enhanced (Streaming)",
        description: "Speechmatics realtime WebSocket transcription with partial and final results."
      )
    ]
  }

  func createLiveTranscriber(
    apiKey: String,
    model: String = "speechmatics/enhanced-streaming",
    language: String? = nil,
    sampleRate: Int = 16000
  ) -> SpeechmaticsLiveTranscriber {
    SpeechmaticsLiveTranscriber(
      apiKey: apiKey,
      model: Self.realtimeModelName(from: model),
      language: language.map(Self.extractLanguageCode(from:)),
      sampleRate: sampleRate
    )
  }

  static func realtimeModelName(from modelID: String) -> String {
    let raw = modelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "speechmatics/", with: "")
      .replacingOccurrences(of: "-streaming", with: "")
    return raw.isEmpty ? "enhanced" : raw
  }

  static func extractLanguageCode(from locale: String) -> String {
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
      responseHeaders: response?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        if let key = pair.key as? String {
          result[key] = String(describing: pair.value)
        }
      } ?? [:],
      responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
      errorDescription: error?.localizedDescription
    )
  }
}

// MARK: - WebSocket response types

struct SpeechmaticsTranscriptEvent: Sendable {
  let text: String
  let isFinal: Bool
  let startTime: TimeInterval
  let endTime: TimeInterval
  let segments: [TranscriptionSegment]
  let confidence: Double?
}

private struct SpeechmaticsEnvelope: Decodable {
  let message: String
}

private struct SpeechmaticsTranscriptMetadata: Decodable {
  let startTime: TimeInterval
  let endTime: TimeInterval
  let transcript: String

  private enum CodingKeys: String, CodingKey {
    case startTime = "start_time"
    case endTime = "end_time"
    case transcript
  }
}

private struct SpeechmaticsTranscriptResponse: Decodable {
  let message: String
  let metadata: SpeechmaticsTranscriptMetadata
  let results: [SpeechmaticsResult]
}

private struct SpeechmaticsResult: Decodable {
  let type: String
  let startTime: TimeInterval?
  let endTime: TimeInterval?
  let alternatives: [SpeechmaticsAlternative]

  private enum CodingKeys: String, CodingKey {
    case type
    case startTime = "start_time"
    case endTime = "end_time"
    case alternatives
  }
}

private struct SpeechmaticsAlternative: Decodable {
  let content: String
  let confidence: Double?
  let speaker: String?
}

private struct SpeechmaticsAudioAddedMessage: Decodable {
  let seqNo: Int

  private enum CodingKeys: String, CodingKey {
    case seqNo = "seq_no"
  }
}

private struct SpeechmaticsPreStartAudioFlush {
  let task: URLSessionWebSocketTask?
  let frames: [Data]
  let continuation: CheckedContinuation<Bool, Never>?
}

private struct SpeechmaticsOutboundFrame {
  let task: URLSessionWebSocketTask
  let message: URLSessionWebSocketTask.Message
  let completion: (Error?) -> Void
}

private struct SpeechmaticsErrorMessage: Decodable {
  let type: String?
  let reason: String?
}

// MARK: - Live Transcriber

// swiftlint:disable type_body_length
final class SpeechmaticsLiveTranscriber: @unchecked Sendable {
  static let minimumChunkBytes = 3_200
  static let preferredChunkBytes = 3_200

  private static let websocketHost = "eu.rt.speechmatics.com"
  private static let websocketPath = "/v2/"
  private static let preStartByteLimit = 16_000 * 2 * 5

  private let apiKey: String
  private let model: String
  private let language: String?
  private let sampleRate: Int
  private let session: URLSession
  private let bufferPool: AudioBufferPool
  private let logger = Logger(subsystem: "com.speak.app", category: "SpeechmaticsLiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()
  private let outboundSendQueue = DispatchQueue(label: "com.speak.app.speechmatics.outbound")

  private var webSocketTask: URLSessionWebSocketTask?
  private var onTranscript: ((SpeechmaticsTranscriptEvent) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping = false
  private var recognitionStarted = false
  private var preStartAudioBuffer: [Data] = []
  private var sentAudioFrameCount = 0
  private var lastAcknowledgedSeqNo = -1
  private var endOfTranscriptReceived = false
  private var endOfTranscriptContinuation: CheckedContinuation<Void, Never>?
  private var recognitionStartedContinuation: CheckedContinuation<Bool, Never>?
  private var outboundFrames: [SpeechmaticsOutboundFrame] = []
  private var outboundSendInFlight = false

  init(
    apiKey: String,
    model: String = "enhanced",
    language: String? = nil,
    sampleRate: Int = 16000,
    session: URLSession = .shared,
    bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
  ) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.model = model
    self.language = language
    self.sampleRate = sampleRate
    self.session = session
    self.bufferPool = bufferPool
  }

  func start(
    onTranscript: @escaping (SpeechmaticsTranscriptEvent) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    withStateLock {
      self.isStopping = false
      self.recognitionStarted = false
      self.preStartAudioBuffer = []
      self.sentAudioFrameCount = 0
      self.lastAcknowledgedSeqNo = -1
      self.endOfTranscriptReceived = false
      self.endOfTranscriptContinuation = nil
      self.recognitionStartedContinuation = nil
      self.onTranscript = onTranscript
      self.onError = onError
    }
    connectWebSocket()
  }

  func sendAudio(_ audioData: Data) {
    enum SendAction {
      case sendDirectly(URLSessionWebSocketTask)
      case buffered
    }

    let action = withStateLock { () -> SendAction in
      if self.recognitionStarted,
         let task = self.webSocketTask,
         task.state == .running {
        return .sendDirectly(task)
      } else {
        self.preStartAudioBuffer.append(audioData)
        var totalBytes = self.preStartAudioBuffer.reduce(0) { $0 + $1.count }
        while totalBytes > Self.preStartByteLimit, !self.preStartAudioBuffer.isEmpty {
          totalBytes -= self.preStartAudioBuffer.removeFirst().count
        }
        return .buffered
      }
    }

    switch action {
    case .sendDirectly(let task):
      sendAudioFrame(audioData, on: task)
    case .buffered:
      return
    }
  }

  func sendEndOfStream() {
    guard let task = currentWebSocketTask(), task.state == .running else { return }
    let lastSeqNo = withStateLock {
      Self.endOfStreamLastSequenceNumber(
        lastAcknowledged: self.lastAcknowledgedSeqNo,
        sentFrameCount: self.sentAudioFrameCount
      )
    }
    let payload: [String: Any] = [
      "message": "EndOfStream",
      "last_seq_no": lastSeqNo
    ]
    sendJSONPayload(payload, on: task)
  }

  func waitForRecognitionStarted(timeout: TimeInterval = 1.5) async -> Bool {
    await withCheckedContinuation { continuation in
      let shouldWait = withStateLock { () -> Bool in
        guard !self.recognitionStarted else { return false }
        self.recognitionStartedContinuation = continuation
        return true
      }
      if !shouldWait {
        continuation.resume(returning: true)
        return
      }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self else { return }
        let pending = self.withStateLock { () -> CheckedContinuation<Bool, Never>? in
          let saved = self.recognitionStartedContinuation
          self.recognitionStartedContinuation = nil
          return saved
        }
        pending?.resume(returning: false)
      }
    }
  }

  func awaitEndOfTranscript(timeout: TimeInterval = 2.0) async {
    await withCheckedContinuation { continuation in
      let shouldWait = withStateLock { () -> Bool in
        guard !self.isStopping, !self.endOfTranscriptReceived else { return false }
        self.endOfTranscriptContinuation = continuation
        return true
      }
      if !shouldWait {
        continuation.resume()
        return
      }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self else { return }
        let pending = self.withStateLock { () -> CheckedContinuation<Void, Never>? in
          let saved = self.endOfTranscriptContinuation
          self.endOfTranscriptContinuation = nil
          return saved
        }
        pending?.resume()
      }
    }
  }

  func waitForPendingSends(timeout: TimeInterval = 1.5) async {
    let sendGroup = pendingSendGroup
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        _ = sendGroup.wait(timeout: .now() + timeout)
        continuation.resume()
      }
    }
  }

  func stop() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      guard !self.isStopping else { return nil }
      self.isStopping = true
      return self.webSocketTask
    }
    bufferPool.logMetrics()

    let pending = withStateLock { () -> CheckedContinuation<Void, Never>? in
      let saved = self.endOfTranscriptContinuation
      self.endOfTranscriptContinuation = nil
      return saved
    }
    pending?.resume()

    let recognitionPending = withStateLock { () -> CheckedContinuation<Bool, Never>? in
      let saved = self.recognitionStartedContinuation
      self.recognitionStartedContinuation = nil
      return saved
    }
    recognitionPending?.resume(returning: false)

    guard let task else { return }
    if task.state == .running {
      task.cancel(with: .normalClosure, reason: nil)
    }
    withStateLock {
      if self.webSocketTask === task {
        self.webSocketTask = nil
      }
    }
    logger.info("Speechmatics WebSocket connection closed")
  }

  static func startRecognitionPayload(
    language: String? = nil,
    model: String = "enhanced",
    sampleRate: Int = 16000
  ) throws -> String {
    let languageCode = language.map(SpeechmaticsTranscriptionProvider.extractLanguageCode(from:)) ?? "en"
    let payload: [String: Any] = [
      "message": "StartRecognition",
      "audio_format": [
        "type": "raw",
        "encoding": "pcm_s16le",
        "sample_rate": sampleRate
      ],
      "transcription_config": [
        "language": languageCode,
        "model": model,
        "max_delay": 0.7,
        "enable_partials": true
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw SpeechmaticsLiveError.encodingFailed
    }
    return json
  }

  static func transcriptEvent(from json: String) -> SpeechmaticsTranscriptEvent? {
    guard let data = json.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(SpeechmaticsEnvelope.self, from: data),
          envelope.message == "AddPartialTranscript" || envelope.message == "AddTranscript",
          let response = try? JSONDecoder().decode(SpeechmaticsTranscriptResponse.self, from: data)
    else {
      return nil
    }

    let text = response.metadata.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let isFinal = response.message == "AddTranscript"
    let segments = isFinal ? Self.segments(from: response.results) : []
    let confidence = isFinal ? Self.averageConfidence(from: response.results) : nil
    return SpeechmaticsTranscriptEvent(
      text: text,
      isFinal: isFinal,
      startTime: response.metadata.startTime,
      endTime: response.metadata.endTime,
      segments: segments,
      confidence: confidence
    )
  }

  static func endOfStreamLastSequenceNumber(lastAcknowledged: Int, sentFrameCount: Int) -> Int {
    max(lastAcknowledged, sentFrameCount, 0)
  }

  private func connectWebSocket() {
    var components = URLComponents()
    components.scheme = "wss"
    components.host = Self.websocketHost
    components.path = Self.websocketPath
    guard let url = components.url else {
      currentOnError()?(SpeechmaticsLiveError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let task = session.webSocketTask(with: request)
    let shouldReceive = withStateLock { () -> Bool in
      guard !self.isStopping else { return false }
      self.webSocketTask = task
      task.resume()
      return true
    }
    guard shouldReceive else {
      task.cancel(with: .goingAway, reason: nil)
      return
    }

    sendStartRecognition(on: task)
    logger.info("Speechmatics WebSocket connecting (model: \(self.model, privacy: .public))")
    receiveMessages()
  }

  private func sendStartRecognition(on task: URLSessionWebSocketTask) {
    do {
      let payload = try Self.startRecognitionPayload(language: language, model: model, sampleRate: sampleRate)
      enqueueOutbound(.string(payload), on: task) { [weak self] error in
        guard let self else { return }
        if let error, !self.isStoppingState() {
          self.currentOnError()?(error)
        }
      }
    } catch {
      currentOnError()?(error)
    }
  }

  private func sendAudioFrame(_ audioData: Data, on task: URLSessionWebSocketTask) {
    var buffer = bufferPool.checkout()
    buffer.append(audioData)
    withStateLock {
      self.sentAudioFrameCount += 1
    }

    let dataToSend = buffer
    enqueueOutbound(.data(dataToSend), on: task) { [weak self] error in
      guard let self else { return }
      var returnBuffer = buffer
      self.bufferPool.returnBuffer(&returnBuffer)
      if let error {
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
        self.logger.error("Failed to send audio: \(error.localizedDescription, privacy: .public)")
        self.currentOnError()?(error)
      }
    }
  }

  private func sendJSONPayload(_ payload: [String: Any], on task: URLSessionWebSocketTask) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
          let json = String(data: data, encoding: .utf8)
    else { return }
    enqueueOutbound(.string(json), on: task) { [weak self] error in
      guard let self else { return }
      if let error, !self.isStoppingState(), !self.shouldIgnoreSocketError(error) {
        self.currentOnError()?(error)
      }
    }
  }

  private func enqueueOutbound(
    _ message: URLSessionWebSocketTask.Message,
    on task: URLSessionWebSocketTask,
    completion: @escaping (Error?) -> Void
  ) {
    pendingSendGroup.enter()
    outboundSendQueue.async {
      self.outboundFrames.append(
        SpeechmaticsOutboundFrame(task: task, message: message, completion: completion)
      )
      self.sendNextOutboundFrameIfNeeded()
    }
  }

  private func sendNextOutboundFrameIfNeeded() {
    dispatchPrecondition(condition: .onQueue(outboundSendQueue))
    guard !outboundSendInFlight, let frame = outboundFrames.first else { return }
    outboundSendInFlight = true
    frame.task.send(frame.message) { [weak self] error in
      guard let self else { return }
      self.outboundSendQueue.async {
        let completed = self.outboundFrames.removeFirst()
        self.outboundSendInFlight = false
        completed.completion(error)
        self.pendingSendGroup.leave()
        self.sendNextOutboundFrameIfNeeded()
      }
    }
  }

  private func receiveMessages() {
    guard let task = currentWebSocketTask() else { return }
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveMessages()
      case .failure(let error):
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
        self.logger.error("Speechmatics receive error: \(error.localizedDescription, privacy: .public)")
        self.currentOnError()?(self.mapConnectionError(error))
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
    guard let data = json.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(SpeechmaticsEnvelope.self, from: data)
    else { return }

    switch envelope.message {
    case "RecognitionStarted":
      handleRecognitionStarted()
    case "AudioAdded":
      if let message = try? JSONDecoder().decode(SpeechmaticsAudioAddedMessage.self, from: data) {
        withStateLock { self.lastAcknowledgedSeqNo = max(self.lastAcknowledgedSeqNo, message.seqNo) }
      }
    case "AddPartialTranscript", "AddTranscript":
      guard let event = Self.transcriptEvent(from: json) else { return }
      currentOnTranscript()?(event)
    case "EndOfTranscript":
      let pending = withStateLock { () -> CheckedContinuation<Void, Never>? in
        self.endOfTranscriptReceived = true
        let saved = self.endOfTranscriptContinuation
        self.endOfTranscriptContinuation = nil
        return saved
      }
      pending?.resume()
    case "Error":
      let decoded = try? JSONDecoder().decode(SpeechmaticsErrorMessage.self, from: data)
      let detail = decoded?.reason ?? decoded?.type ?? "Unknown Speechmatics error"
      currentOnError()?(mapServerError(type: decoded?.type, detail: detail))
    default:
      break
    }
  }

  private func handleRecognitionStarted() {
    while true {
      let flush = withStateLock { () -> SpeechmaticsPreStartAudioFlush in
        let frames = self.preStartAudioBuffer
        self.preStartAudioBuffer = []
        let continuation: CheckedContinuation<Bool, Never>?
        if frames.isEmpty {
          self.recognitionStarted = true
          continuation = self.recognitionStartedContinuation
          self.recognitionStartedContinuation = nil
        } else {
          continuation = nil
        }
        return SpeechmaticsPreStartAudioFlush(
          task: self.webSocketTask,
          frames: frames,
          continuation: continuation
        )
      }
      guard !flush.frames.isEmpty else {
        flush.continuation?.resume(returning: true)
        return
      }
      if let task = flush.task, task.state == .running {
        logger.info("Flushing \(flush.frames.count) pre-start audio frames to Speechmatics")
        for frame in flush.frames {
          sendAudioFrame(frame, on: task)
        }
      }
    }
  }

  private static func segments(from results: [SpeechmaticsResult]) -> [TranscriptionSegment] {
    results.compactMap { result in
      guard let alternative = result.alternatives.first else { return nil }
      let content = alternative.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { return nil }
      return TranscriptionSegment(
        startTime: result.startTime ?? 0,
        endTime: result.endTime ?? result.startTime ?? 0,
        text: content,
        isFinal: true,
        confidence: alternative.confidence
      )
    }
  }

  private static func averageConfidence(from results: [SpeechmaticsResult]) -> Double? {
    let confidences = results.compactMap { $0.alternatives.first?.confidence }
    guard !confidences.isEmpty else { return nil }
    return confidences.reduce(0, +) / Double(confidences.count)
  }

  private func mapConnectionError(_ error: Error) -> Error {
    let nsError = error as NSError
    let description = nsError.localizedDescription.lowercased()
    if nsError.code == 401 || nsError.code == 403
      || description.contains("401") || description.contains("403")
      || description.contains("unauthorized") || description.contains("not authorised")
      || description.contains("forbidden") {
      return SpeechmaticsLiveError.invalidAPIKey
    }
    return error
  }

  private func mapServerError(type: String?, detail: String) -> Error {
    let errorType = type?.lowercased() ?? ""
    if errorType.contains("not_authorised") || errorType.contains("not authorized") {
      return SpeechmaticsLiveError.invalidAPIKey
    }
    return SpeechmaticsLiveError.serverError(detail)
  }

  private func shouldIgnoreSocketError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
    if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
      return true
    }
    return false
  }

  private func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  private func currentWebSocketTask() -> URLSessionWebSocketTask? {
    withStateLock { self.webSocketTask }
  }

  private func isStoppingState() -> Bool {
    withStateLock { self.isStopping }
  }

  private func currentOnTranscript() -> ((SpeechmaticsTranscriptEvent) -> Void)? {
    withStateLock { self.onTranscript }
  }

  private func currentOnError() -> ((Error) -> Void)? {
    withStateLock { self.onError }
  }
}
// swiftlint:enable type_body_length
