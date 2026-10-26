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
      return "This Gladia model is only available for live streaming in Speak."
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
  private let independentCleanup: Bool

  init(
    session: URLSession = .shared, baseURL: URL = GladiaLiveTranscriber.defaultBaseURL,
    independentCleanup: Bool = false
  ) {
    self.session = session
    self.baseURL = baseURL
    self.independentCleanup = independentCleanup
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    guard model.trimmingCharacters(in: .whitespacesAndNewlines) == GladiaBatchClient.catalogID else {
      throw BatchTranscriptionJobError.unsupportedModel("Gladia")
    }
    let client = GladiaBatchClient(session: session, baseURL: baseURL)
    return try await (independentCleanup ? client.withIndependentCleanup() : client).transcribeFile(
      at: url, apiKey: apiKey, model: model, language: language
    )
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
        // The listing body echoes previous sessions' transcripts, so it is deliberately
        // left out of the debug snapshot on success.
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http)
        return .success(message: "Gladia API key validated", debug: debug)
      case 401, 403:
        let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
        return .failure(message: "Gladia rejected the key (HTTP \(http.statusCode))", debug: debug)
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

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
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
  private let logger = SpeakLogger.logger(category: "GladiaLiveTranscriber")
  private let stateLock = NSLock()

  private let makeSocket: @Sendable (URLRequest) -> any GladiaMacWebSocket
  private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
  private let beforeStopHandoff: @Sendable () -> Void
  private let didRegisterFinishWaiter: @Sendable () -> Void
  private var finalization = GladiaMacFinalization()
  private var webSocketTask: (any GladiaMacWebSocket)?
  private var initTask: Task<Void, Never>?
  private var pendingAudio = Data()
  private var isStopping = false

  convenience init(
    apiKey: String,
    model: String = "gladia/solaria-1-streaming",
    language: String? = nil,
    sampleRate: Int = 16_000,
    session: URLSession = .shared,
    baseURL: URL = GladiaLiveTranscriber.defaultBaseURL
  ) {
    self.init(
      apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
      session: session, baseURL: baseURL, makeSocket: { session.webSocketTask(with: $0) }
    )
  }

  init(
    apiKey: String, model: String = "gladia/solaria-1-streaming", language: String? = nil,
    sampleRate: Int = 16_000, session: URLSession = .shared,
    baseURL: URL = GladiaLiveTranscriber.defaultBaseURL,
    makeSocket: @escaping @Sendable (URLRequest) -> any GladiaMacWebSocket,
    beforeStopHandoff: @escaping @Sendable () -> Void = {},
    didRegisterFinishWaiter: @escaping @Sendable () -> Void = {},
    schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, action in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action)
    }
  ) {
    self.makeSocket = makeSocket
    self.beforeStopHandoff = beforeStopHandoff
    self.didRegisterFinishWaiter = didRegisterFinishWaiter
    self.schedule = schedule
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
    stop()
    let active = GladiaMacFinalization(onTranscript: onTranscript, onError: onError)
    let oldInitTask = withStateLock { () -> Task<Void, Never>? in
      finalization = active
      isStopping = false
      pendingAudio.removeAll(keepingCapacity: true)
      let old = initTask
      initTask = nil
      return old
    }
    oldInitTask?.cancel()

    let task = Task { [weak self] in
      guard let self else { return }
      await self.initiateAndConnect(active)
    }
    withStateLock {
      if finalization === active, !isStopping { self.initTask = task } else { task.cancel() }
    }
  }

  var snapshot: GladiaMacFinalization.Snapshot { withStateLock { finalization }.snapshot }

  func takeFailureForReporting() -> Error? { withStateLock { finalization }.takeFailureForReporting() }

  func finishAndWait(timeout: TimeInterval) async -> GladiaMacFinalization.Snapshot {
    let active = withStateLock { finalization }
    return await withTaskCancellationHandler {
      let result = await active.wait(
        timeout: timeout, schedule: schedule, registered: didRegisterFinishWaiter
      ) { [weak self] in
        guard let self else { return }
        self.sendStopRecording(active)
      }
      self.stop(active)
      return result
    } onCancel: { [weak self] in self?.stop(active) }
  }

  func sendAudio(_ audioData: Data) {
    let (active, task, stopping) = withStateLock { (finalization, webSocketTask, isStopping) }
    guard active.acceptsAudio, !stopping else { return }
    guard let task, task.state == .running else {
      bufferPendingAudio(audioData, active: active)
      return
    }
    flushPendingAudio(to: task, active: active)
    send(audioData, to: task, active: active)
  }

  func sendStopRecording() { sendStopRecording(withStateLock { finalization }) }

  private func sendStopRecording(_ active: GladiaMacFinalization) {
    let task = withStateLock { finalization === active && !isStopping ? webSocketTask : nil }
    guard let task, task.state == .running, active.claimStop() else { return }
    let sendGroup = active.pendingSendGroup
    sendGroup.enter()
    beforeStopHandoff()
    guard isCurrent(active), active.handOffStop() else { sendGroup.leave(); return }
    task.send(.string(Self.stopRecordingMessage())) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self, self.isCurrent(active) else { return }
      if let error { self.fail(self.mapConnectionError(error), active) }
    }
  }

  func waitForPendingSends(timeout: TimeInterval = 1.5, active: GladiaMacFinalization? = nil) async {
    let sendGroup = (active ?? withStateLock { finalization }).pendingSendGroup
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

  func stop() { stop(withStateLock { finalization }) }

  private func stop(_ active: GladiaMacFinalization) {
    let task = withStateLock { () -> (any GladiaMacWebSocket)? in
      guard finalization === active, !isStopping else { return nil }
      isStopping = true
      initTask?.cancel()
      initTask = nil
      let task = webSocketTask
      webSocketTask = nil
      return task
    }
    active.complete(error: CancellationError())
    task?.cancel(with: .normalClosure, reason: nil)
  }

  private func isCurrent(_ active: GladiaMacFinalization) -> Bool {
    withStateLock { finalization === active && !isStopping }
  }

  private func fail(_ error: Error, _ active: GladiaMacFinalization) {
    guard isCurrent(active) else { return }
    active.complete(error: error, beforeResume: { active.onError(error) })
    stop(active)
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
      languageConfig: GladiaLanguageConfig.from(language: language),
      messagesConfig: GladiaMessagesConfig.transcriptsOnly
    )
    var request = URLRequest(url: baseURL.appendingPathComponent("v2/live"))
    request.httpMethod = "POST"
    request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-gladia-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)
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

  private func initiateAndConnect(_ active: GladiaMacFinalization) async {
    do {
      let response = try await initiateLiveSession()
      guard let url = URL(string: response.url) else {
        throw GladiaLiveError.invalidInitResponse
      }
      guard isCurrent(active) else { return }
      connectWebSocket(url: url, active: active)
    } catch {
      fail(mapConnectionError(error), active)
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

  private func connectWebSocket(url: URL, active: GladiaMacFinalization) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    let task = makeSocket(request)
    let shouldReceive = withStateLock { () -> Bool in
      guard finalization === active, !isStopping else { return false }
      webSocketTask = task
      return true
    }
    guard shouldReceive else {
      task.cancel(with: .goingAway, reason: nil)
      return
    }
    task.resume()
    logger.info("Gladia WebSocket connecting")
    flushPendingAudio(to: task, active: active)
    receiveMessages(task: task, active: active)
    if active.isFinishing {
      Task { [weak self] in
        guard let self else { return }
        await self.waitForPendingSends(active: active)
        self.sendStopRecording(active)
      }
    }
  }

  private func send(_ audioData: Data, to task: any GladiaMacWebSocket, active: GladiaMacFinalization) {
    guard isCurrent(active) else { return }
    let sendGroup = active.pendingSendGroup
    sendGroup.enter()
    task.send(.data(audioData)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      if let error {
        guard self.isCurrent(active) else { return }
        self.fail(self.mapConnectionError(error), active)
      }
    }
  }

  private func receiveMessages(task: any GladiaMacWebSocket, active: GladiaMacFinalization) {
    guard isCurrent(active) else { return }
    task.receive { [weak self, weak task] result in
      guard let self, let task, self.isCurrent(active) else { return }
      switch result {
      case .success(let message):
        switch message {
        case .string(let text): self.parseResponse(text, active: active)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) { self.parseResponse(text, active: active) }
        @unknown default: break
        }
        self.receiveMessages(task: task, active: active)
      case .failure(let error): self.fail(self.mapConnectionError(error), active)
      }
    }
  }

  private func parseResponse(_ json: String, active: GladiaMacFinalization) {
    if let event = Self.transcriptEvent(from: json) {
      if active.record(event) { active.onTranscript(event) }
      return
    }
    guard let data = json.data(using: .utf8) else { return }
    if let lifecycle = try? JSONDecoder().decode(GladiaLifecycleMessage.self, from: data),
      lifecycle.type == "end_session" {
      active.ended()
      stop(active)
      return
    }
    guard let envelope = try? JSONDecoder().decode(GladiaLiveMessage.self, from: data),
      let error = envelope.error else { return }
    let detail = error.message ?? error.exception ?? "Unknown server error"
    fail(GladiaLiveError.serverError(detail), active)
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

  private func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  private func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  private func bufferPendingAudio(_ audioData: Data, active: GladiaMacFinalization) {
    withStateLock {
      guard finalization === active, !isStopping, active.acceptsAudio else { return }
      pendingAudio.append(audioData)
      let maxBufferedBytes = Self.preferredChunkBytes * 50
      if pendingAudio.count > maxBufferedBytes {
        pendingAudio = Data(pendingAudio.suffix(maxBufferedBytes))
      }
    }
  }

  private func flushPendingAudio(to task: any GladiaMacWebSocket, active: GladiaMacFinalization) {
    let buffered = withStateLock { () -> Data in
      guard finalization === active, !isStopping else { return Data() }
      let snapshot = pendingAudio
      pendingAudio.removeAll(keepingCapacity: true)
      return snapshot
    }
    guard !buffered.isEmpty else { return }
    send(buffered, to: task, active: active)
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

  /// The canonical Gladia mapping (`GladiaLive.languageCode`), shared with the
  /// iOS and Windows client and the batch job: a listed language pins the
  /// session, anything else detects it with code switching.
  static func from(language: String?) -> GladiaLanguageConfig {
    guard let code = GladiaLive.languageCode(for: language) else { return automaticCodeSwitching }
    return GladiaLanguageConfig(languages: [code], codeSwitching: false)
  }

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

private struct GladiaLifecycleMessage: Decodable { let type: String? }
