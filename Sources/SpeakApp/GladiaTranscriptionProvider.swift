// swiftlint:disable file_length
import Foundation
import os.log
import SpeakCore

enum GladiaLiveError: LocalizedError {
  case missingAPIKey
  case invalidURLComponents
  case invalidAPIKey
  case invalidInitResponse
  case connectionFailed
  case batchNotSupported
  case serverError(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Gladia API key is missing. Please add it in Settings → Gladia."
    case .invalidURLComponents:
      return "Failed to construct Gladia request URL."
    case .invalidAPIKey:
      return "Gladia API key is invalid. Check your key in Settings → Gladia."
    case .invalidInitResponse:
      return "Gladia returned an invalid live-session response."
    case .connectionFailed:
      return "Failed to establish live transcription with Gladia."
    case .batchNotSupported:
      return "Gladia Solaria-1 is currently only available for live streaming in Speak."
    case .serverError(let message):
      return "Gladia transcription failed: \(message)"
    }
  }
}

struct GladiaTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "gladia",
    displayName: "Gladia",
    systemImage: "waveform.badge.sparkles",
    tintColor: "teal",
    website: "https://www.gladia.io"
  )

  private let session: URLSession
  private let baseURL: URL

  init(session: URLSession = .shared, baseURL: URL = GladiaLiveTranscriber.defaultBaseURL) {
    self.session = session
    self.baseURL = baseURL
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    _ = (url, apiKey, model, language)
    throw GladiaLiveError.batchNotSupported
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    var request = URLRequest(url: baseURL.appendingPathComponent("v2/live"))
    request.httpMethod = "GET"
    request.setValue(trimmed, forHTTPHeaderField: "x-gladia-key")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      switch http.statusCode {
      case 200..<300:
        let debug = debugSnapshot(request: request, response: http, data: nil)
        return .success(message: "Gladia API key validated", debug: debug)
      case 401, 403:
        let debug = debugSnapshot(request: request, response: http, data: data)
        return .failure(message: "Gladia rejected the key (HTTP \(http.statusCode))", debug: debug)
      default:
        let debug = debugSnapshot(request: request, response: http, data: data)
        return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
      }
    } catch {
      return .failure(message: "Validation failed: \(error.localizedDescription)")
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    [
      ModelCatalog.Option(
        id: "gladia/solaria-1-streaming",
        displayName: "Solaria-1 Streaming",
        description: "Gladia Solaria-1 real-time multilingual STT with automatic language detection."
      )
    ]
  }

  func createLiveTranscriber(
    apiKey: String,
    model: String = "gladia/solaria-1-streaming",
    language: String? = nil,
    sampleRate: Int = 16_000
  ) -> GladiaLiveTranscriber {
    GladiaLiveTranscriber(
      apiKey: apiKey,
      model: model,
      language: language,
      sampleRate: sampleRate,
      session: session,
      baseURL: baseURL
    )
  }

  private func debugSnapshot(
    request: URLRequest,
    response: HTTPURLResponse,
    data: Data?
  ) -> APIKeyValidationDebugSnapshot {
    APIKeyValidationDebugSnapshot(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "GET",
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
      statusCode: response.statusCode,
      responseHeaders: response.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
        guard let key = entry.key as? String else { return }
        partialResult[key] = String(describing: entry.value)
      },
      responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
      errorDescription: nil
    )
  }
}

struct GladiaTranscriptEvent: Equatable, Sendable {
  let text: String
  let isFinal: Bool
  let confidence: Double?
}

// swiftlint:disable:next type_body_length
final class GladiaLiveTranscriber: @unchecked Sendable {
  static let defaultBaseURL = URL(string: "https://api.gladia.io")!
  static let preferredChunkBytes = 3_200
  static let minimumChunkBytes = 1_600

  private let apiKey: String
  private let model: String
  private let language: String?
  private let sampleRate: Int
  private let session: URLSession
  private let baseURL: URL
  private let logger = Logger(subsystem: "com.speak.app", category: "GladiaLiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()

  private var webSocketTask: URLSessionWebSocketTask?
  private var initTask: Task<Void, Never>?
  private var pendingAudio = Data()
  private var onTranscript: ((GladiaTranscriptEvent) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping = false

  init(
    apiKey: String,
    model: String = "gladia/solaria-1-streaming",
    language: String? = nil,
    sampleRate: Int = 16_000,
    session: URLSession = .shared,
    baseURL: URL = GladiaLiveTranscriber.defaultBaseURL
  ) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.model = model
    self.language = language
    self.sampleRate = sampleRate
    self.session = session
    self.baseURL = baseURL
  }

  func start(
    onTranscript: @escaping (GladiaTranscriptEvent) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    withStateLock {
      isStopping = false
      pendingAudio.removeAll(keepingCapacity: true)
      self.onTranscript = onTranscript
      self.onError = onError
    }

    initTask = Task { [weak self] in
      await self?.initiateAndConnect()
    }
  }

  func sendAudio(_ audioData: Data) {
    guard let task = currentWebSocketTask(), task.state == .running else {
      bufferPendingAudio(audioData)
      return
    }
    flushPendingAudio(to: task)
    send(audioData, to: task)
  }

  func sendStopRecording() {
    guard let task = currentWebSocketTask(), task.state == .running else { return }
    let message = Self.stopRecordingMessage()
    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.string(message)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      if let error, !self.isStoppingState(), !self.shouldIgnoreSocketError(error) {
        self.currentOnError()?(error)
      }
    }
  }

  func waitForPendingSends(timeout: TimeInterval = 1.5) async {
    let sendGroup = pendingSendGroup
    await withCheckedContinuation { continuation in
      let lock = NSLock()
      var didResume = false
      let resumeOnce = {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume()
      }
      sendGroup.notify(queue: .global()) {
        resumeOnce()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        resumeOnce()
      }
    }
  }

  func stop() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      guard !isStopping else { return nil }
      isStopping = true
      initTask?.cancel()
      initTask = nil
      return webSocketTask
    }
    guard let task else { return }
    if task.state == .running {
      task.cancel(with: .normalClosure, reason: nil)
    }
    withStateLock {
      if webSocketTask === task { webSocketTask = nil }
    }
  }

  nonisolated static func stopRecordingMessage() -> String {
    #"{"type":"stop_recording"}"#
  }

  nonisolated static func liveModelName(from model: String) -> String {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    let cleaned = name.replacingOccurrences(of: "-streaming", with: "")
    return cleaned.isEmpty ? "solaria-1" : cleaned
  }

  nonisolated static func makeInitRequest(
    apiKey: String,
    model: String,
    language: String?,
    sampleRate: Int,
    baseURL: URL = defaultBaseURL
  ) throws -> URLRequest {
    let payload = GladiaLiveInitRequest(
      model: liveModelName(from: model),
      sampleRate: sampleRate,
      languageConfig: GladiaLanguageConfig.automaticCodeSwitching,
      messagesConfig: GladiaMessagesConfig.transcriptsOnly
    )
    var request = URLRequest(url: baseURL.appendingPathComponent("v2/live"))
    request.httpMethod = "POST"
    request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-gladia-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)
    _ = language
    return request
  }

  nonisolated static func transcriptEvent(from json: String) -> GladiaTranscriptEvent? {
    guard let data = json.data(using: .utf8) else { return nil }
    guard let envelope = try? JSONDecoder().decode(GladiaLiveMessage.self, from: data) else { return nil }
    guard envelope.type == "transcript" else { return nil }
    guard let transcript = envelope.data, let utterance = transcript.utterance else { return nil }
    let text = utterance.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return nil }
    return GladiaTranscriptEvent(
      text: text,
      isFinal: transcript.isFinal,
      confidence: utterance.confidence
    )
  }

  private func initiateAndConnect() async {
    do {
      let response = try await initiateLiveSession()
      guard let url = URL(string: response.url) else {
        throw GladiaLiveError.invalidInitResponse
      }
      connectWebSocket(url: url)
    } catch {
      guard !isStoppingState() else { return }
      currentOnError()?(mapConnectionError(error))
    }
  }

  private func initiateLiveSession() async throws -> GladiaLiveInitResponse {
    let request = try Self.makeInitRequest(
      apiKey: apiKey,
      model: model,
      language: language,
      sampleRate: sampleRate,
      baseURL: baseURL
    )
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GladiaLiveError.invalidInitResponse
    }
    guard http.statusCode == 201 else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, body)
    }
    return try JSONDecoder().decode(GladiaLiveInitResponse.self, from: data)
  }

  private func connectWebSocket(url: URL) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    let task = session.webSocketTask(with: request)
    let shouldReceive = withStateLock { () -> Bool in
      guard !isStopping else { return false }
      webSocketTask = task
      task.resume()
      return true
    }
    guard shouldReceive else {
      task.cancel(with: .goingAway, reason: nil)
      return
    }
    logger.info("Gladia WebSocket connecting")
    flushPendingAudio(to: task)
    receiveMessages()
  }

  private func send(_ audioData: Data, to task: URLSessionWebSocketTask) {
    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.data(audioData)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      if let error {
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
        self.currentOnError()?(self.mapConnectionError(error))
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
    if let event = Self.transcriptEvent(from: json) {
      currentOnTranscript()?(event)
      return
    }

    guard let data = json.data(using: .utf8),
      let envelope = try? JSONDecoder().decode(GladiaLiveMessage.self, from: data),
      let error = envelope.error else {
      return
    }
    let detail = error.message ?? error.exception ?? "Unknown server error"
    currentOnError()?(GladiaLiveError.serverError(detail))
  }

  private func mapConnectionError(_ error: Error) -> Error {
    if case TranscriptionProviderError.httpError(let code, _) = error,
      code == 401 || code == 403 {
      return GladiaLiveError.invalidAPIKey
    }
    let nsError = error as NSError
    let description = nsError.localizedDescription.lowercased()
    if nsError.code == 401 || nsError.code == 403
      || description.contains("401") || description.contains("403")
      || description.contains("unauthorized") || description.contains("forbidden") {
      return GladiaLiveError.invalidAPIKey
    }
    return error
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
    withStateLock { webSocketTask }
  }

  private func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  private func currentOnTranscript() -> ((GladiaTranscriptEvent) -> Void)? {
    withStateLock { onTranscript }
  }

  private func currentOnError() -> ((Error) -> Void)? {
    withStateLock { onError }
  }

  private func bufferPendingAudio(_ audioData: Data) {
    withStateLock {
      pendingAudio.append(audioData)
      let maxBufferedBytes = Self.preferredChunkBytes * 50
      if pendingAudio.count > maxBufferedBytes {
        pendingAudio = Data(pendingAudio.suffix(maxBufferedBytes))
      }
    }
  }

  private func flushPendingAudio(to task: URLSessionWebSocketTask) {
    let buffered = withStateLock { () -> Data in
      let snapshot = pendingAudio
      pendingAudio.removeAll(keepingCapacity: true)
      return snapshot
    }
    guard !buffered.isEmpty else { return }
    send(buffered, to: task)
  }
}

private struct GladiaLiveInitRequest: Encodable {
  let model: String
  let encoding = "wav/pcm"
  let bitDepth = 16
  let sampleRate: Int
  let channels = 1
  let languageConfig: GladiaLanguageConfig
  let messagesConfig: GladiaMessagesConfig

  private enum CodingKeys: String, CodingKey {
    case model
    case encoding
    case bitDepth = "bit_depth"
    case sampleRate = "sample_rate"
    case channels
    case languageConfig = "language_config"
    case messagesConfig = "messages_config"
  }
}

private struct GladiaLanguageConfig: Encodable {
  static let automaticCodeSwitching = GladiaLanguageConfig(languages: [], codeSwitching: true)

  let languages: [String]
  let codeSwitching: Bool

  private enum CodingKeys: String, CodingKey {
    case languages
    case codeSwitching = "code_switching"
  }
}

private struct GladiaMessagesConfig: Encodable {
  static let transcriptsOnly = GladiaMessagesConfig(
    receivePartialTranscripts: true,
    receiveFinalTranscripts: true,
    receiveSpeechEvents: false,
    receivePreProcessingEvents: false,
    receiveRealtimeProcessingEvents: false,
    receivePostProcessingEvents: false,
    receiveAcknowledgments: false,
    receiveErrors: true,
    receiveLifecycleEvents: true
  )

  let receivePartialTranscripts: Bool
  let receiveFinalTranscripts: Bool
  let receiveSpeechEvents: Bool
  let receivePreProcessingEvents: Bool
  let receiveRealtimeProcessingEvents: Bool
  let receivePostProcessingEvents: Bool
  let receiveAcknowledgments: Bool
  let receiveErrors: Bool
  let receiveLifecycleEvents: Bool

  private enum CodingKeys: String, CodingKey {
    case receivePartialTranscripts = "receive_partial_transcripts"
    case receiveFinalTranscripts = "receive_final_transcripts"
    case receiveSpeechEvents = "receive_speech_events"
    case receivePreProcessingEvents = "receive_pre_processing_events"
    case receiveRealtimeProcessingEvents = "receive_realtime_processing_events"
    case receivePostProcessingEvents = "receive_post_processing_events"
    case receiveAcknowledgments = "receive_acknowledgments"
    case receiveErrors = "receive_errors"
    case receiveLifecycleEvents = "receive_lifecycle_events"
  }
}

private struct GladiaLiveInitResponse: Decodable {
  let id: String
  let createdAt: String
  let url: String

  private enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case url
  }
}

private struct GladiaLiveMessage: Decodable {
  let type: String?
  let data: GladiaTranscriptData?
  let error: GladiaServerError?
}

private struct GladiaTranscriptData: Decodable {
  let id: String?
  let isFinal: Bool
  let utterance: GladiaUtterance?

  private enum CodingKeys: String, CodingKey {
    case id
    case isFinal = "is_final"
    case utterance
  }
}

private struct GladiaUtterance: Decodable {
  let text: String?
  let confidence: Double?
}

private struct GladiaServerError: Decodable {
  let statusCode: String?
  let exception: String?
  let message: String?

  private enum CodingKeys: String, CodingKey {
    case statusCode = "status_code"
    case exception
    case message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let intCode = try? container.decode(Int.self, forKey: .statusCode) {
      statusCode = String(intCode)
    } else {
      statusCode = try? container.decode(String.self, forKey: .statusCode)
    }
    exception = try? container.decode(String.self, forKey: .exception)
    message = try? container.decode(String.self, forKey: .message)
  }
}
