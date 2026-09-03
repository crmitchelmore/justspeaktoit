import AVFoundation
import Foundation
import os.log
import SpeakCore

// swiftlint:disable file_length

// MARK: - AssemblyAI Live Transcriber

// swiftlint:disable type_body_length
/// Handles real-time audio streaming to AssemblyAI's v3 WebSocket API.
final class AssemblyAILiveTranscriber: @unchecked Sendable {
  private static let terminationTimeoutSeconds: Double = 3
  private let apiKey: String
  private let sampleRate: Int
  private var webSocketTask: URLSessionWebSocketTask?
  /// Dedicated URLSession for WebSocket traffic. Using `URLSession.shared`
  /// across both REST + WebSocket appears to trigger intermittent
  /// "Socket is not connected" (ENOTCONN) failures during the wss handshake
  /// on macOS. A dedicated, default-configured session avoids that.
  private let session: URLSession
  private let logger = SpeakLogger.logger(category: "AssemblyAILiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()

  private var onTranscript: ((AssemblyAITurnResponse) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping: Bool = false

  private var keyterms: [String]
  private let preferredEndpointHost: AssemblyAIStreamingEndpoint = .europe
  private var currentEndpointHost: AssemblyAIStreamingEndpoint = .europe
  private var hasAttemptedHostFallback: Bool = false
  private var sessionDidBegin: Bool = false
  /// Audio frames captured before `Begin` arrives. AssemblyAI's WebSocket
  /// rejects audio sent before the session is established, and the EU→global
  /// retry path can otherwise lose the first second or two of speech.
  private var preBeginAudioBuffer: [Data] = []
  private static let preBeginAudioByteLimit = 16_000 * 2 * 5 // 5s of 16kHz PCM16

  init(
    apiKey: String,
    sampleRate: Int = 16000,
    keyterms: [String] = [],
    session: URLSession? = nil
  ) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sampleRate = sampleRate
    self.keyterms = keyterms
    let delegate = AssemblyAIWebSocketDelegate()
    self.delegate = delegate
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.default
      config.waitsForConnectivity = true
      config.timeoutIntervalForRequest = 30
      self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    delegate.logger = logger
    self.ownsSession = (session == nil)
  }

  private let ownsSession: Bool

  deinit {
    // Sessions created with a delegate retain that delegate strongly
    // until invalidated; only invalidate sessions we own (tests inject one).
    if ownsSession {
      session.invalidateAndCancel()
    }
  }

  private let delegate: AssemblyAIWebSocketDelegate

  func start(
    onTranscript: @escaping (AssemblyAITurnResponse) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    let endpointHost = withStateLock { () -> AssemblyAIStreamingEndpoint in
      isStopping = false
      self.onTranscript = onTranscript
      self.onError = onError
      hasAttemptedHostFallback = false
      sessionDidBegin = false
      preBeginAudioBuffer = []
      currentEndpointHost = preferredEndpointHost
      return currentEndpointHost
    }

    connectWebSocket(using: endpointHost)
  }

  private func connectWebSocket(using host: AssemblyAIStreamingEndpoint) {
    guard let url = AssemblyAIStreamingRequest.url(
      endpoint: host,
      apiKey: apiKey,
      sampleRate: sampleRate,
      keyterms: keyterms
    ) else {
      currentOnError()?(AssemblyAIError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

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

    logger.info("AssemblyAI WebSocket connecting via \(host.rawValue)")
    receiveMessages()
    scheduleBeginTimeout(for: task)
  }

  private static let beginTimeoutSeconds: Double = 8

  private func scheduleBeginTimeout(for task: URLSessionWebSocketTask) {
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.beginTimeoutSeconds) { [weak self, weak task] in
      guard let self, let task else { return }
      let shouldFire = self.withStateLock { () -> Bool in
        // Only act if THIS connection is still the active one and Begin
        // hasn't arrived. Fallback retries swap webSocketTask, and we don't
        // want a stale timeout from an aborted attempt to surface an error.
        guard !self.sessionDidBegin, !self.isStopping else { return false }
        guard self.webSocketTask === task else { return false }
        self.isStopping = true
        return true
      }
      guard shouldFire else { return }
      self.logger.error(
        "AssemblyAI WebSocket Begin not received within \(Self.beginTimeoutSeconds, privacy: .public)s; surfacing error"
      )
      task.cancel(with: .goingAway, reason: nil)
      self.currentOnError()?(AssemblyAIError.streamingFailed("Begin timeout"))
    }
  }

  func sendAudio(_ audioData: Data) {
    // If the session hasn't begun yet (or we're between EU and global retry),
    // buffer the audio so we don't drop the start of an utterance. The buffer
    // is bounded; oldest frames are discarded if speech outpaces the handshake.
    let snapshot = withStateLock { () -> (URLSessionWebSocketTask?, Bool) in
      (webSocketTask, sessionDidBegin)
    }
    let task = snapshot.0
    let didBegin = snapshot.1
    guard let task, task.state == .running, didBegin else {
      withStateLock {
        preBeginAudioBuffer.append(audioData)
        var totalBytes = preBeginAudioBuffer.reduce(0) { $0 + $1.count }
        while totalBytes > Self.preBeginAudioByteLimit, !preBeginAudioBuffer.isEmpty {
          totalBytes -= preBeginAudioBuffer.removeFirst().count
        }
      }
      return
    }

    sendAudioFrame(audioData, on: task)
  }

  private func sendAudioFrame(_ audioData: Data, on webSocketTask: URLSessionWebSocketTask) {
    let sendGroup = pendingSendGroup
    sendGroup.enter()

    // Send the caller's `Data` straight through. Copying it into a pooled
    // buffer only to hand that buffer back while the send is still in flight
    // forced a copy-on-write (plus a memset) per chunk, because `returnBuffer`
    // zeroes storage the queued message still references.
    webSocketTask.send(.data(audioData)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }

      if let error {
        if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
        self.logger.error("Failed to send audio: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  /// Flush any audio that arrived before the WebSocket session began.
  private func flushPreBeginAudio() {
    let (task, frames) = withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
      let pending = preBeginAudioBuffer
      preBeginAudioBuffer = []
      return (webSocketTask, pending)
    }
    guard let task, task.state == .running, !frames.isEmpty else { return }
    logger.info("Flushing \(frames.count) pre-Begin audio frames to AssemblyAI")
    for frame in frames {
      sendAudioFrame(frame, on: task)
    }
  }

  func sendAudio(from pcmBuffer: AVAudioPCMBuffer) {
    guard let channelData = pcmBuffer.floatChannelData else { return }

    let frameLength = Int(pcmBuffer.frameLength)
    // One `Data` built from a contiguous `[Int16]` rather than a per-sample
    // `Data.append`, with the same clamp-and-scale arithmetic as before.
    let audioData = PCM16Converter.data(from: channelData[0], frameCount: frameLength)

    guard let webSocketTask = currentWebSocketTask(), webSocketTask.state == .running else {
      return
    }

    let sendGroup = pendingSendGroup
    sendGroup.enter()

    webSocketTask.send(.data(audioData)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }

      if let error {
        if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
        self.logger.error("Failed to send audio: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  /// Sends `ForceEndpoint` to AssemblyAI without tearing down the socket so
  /// the server flushes the in-flight turn as a final formatted Turn message
  /// over the still-open WebSocket. The controller calls this, awaits the
  /// final Turn (or its budget timeout), and only *then* invokes `stop()` to
  /// send Terminate and close the socket. Sending ForceEndpoint and Terminate
  /// in the same `stop()` call closed the socket before the formatted final
  /// Turn could arrive — the budget burned on a dead socket.
  func sendForceEndpoint() {
    let task = withStateLock { webSocketTask }
    guard let task, task.state == .running else { return }
    let forceMsg = #"{"type":"ForceEndpoint"}"#
    task.send(.string(forceMsg)) { [weak self] error in
      if let error {
        self?.logger.error("ForceEndpoint send failed: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      guard !isStopping else { return nil }
      isStopping = true
      if webSocketTask?.state != .running {
        webSocketTask = nil
      }
      return webSocketTask
    }

    guard let task, task.state == .running else { return }

    // Terminate flushes in-flight messages. Keep the socket open until the
    // server's final Termination frame so the last transcript is not dropped.
    let terminateMsg = #"{"type":"Terminate"}"#
    task.send(.string(terminateMsg)) { [weak self] error in
      guard let self else { return }
      if error != nil {
        self.completeTermination(for: task)
        return
      }
      self.scheduleTerminationTimeout(for: task)
    }
  }

  private func scheduleTerminationTimeout(for task: URLSessionWebSocketTask) {
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationTimeoutSeconds) { [weak self, weak task] in
      guard let self, let task else { return }
      self.completeTermination(for: task)
    }
  }

  private func completeTermination(for task: URLSessionWebSocketTask) {
    let shouldClose = withStateLock { () -> Bool in
      guard webSocketTask === task else { return false }
      webSocketTask = nil
      return true
    }
    if shouldClose {
      task.cancel(with: .normalClosure, reason: nil)
      logger.info("AssemblyAI WebSocket connection closed")
    }
  }

  // MARK: - Private

  private func receiveMessages() {
    guard let webSocketTask = currentWebSocketTask() else { return }
    webSocketTask.receive { [weak self] result in
      guard let self else { return }

      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveMessages()
      case .failure(let error):
        if self.isStoppingState() { return }
        // URLSessionWebSocketTask fires spurious ENOTCONN (POSIX 57) callbacks
        // around the wss handshake on macOS — sometimes before Begin, sometimes
        // after — but the underlying connection still works and Turn messages
        // arrive on subsequent receive() calls. Re-arm receive() rather than
        // bubbling the error; the isStoppingState() guard above (set on
        // Terminate/Termination) breaks us out when the session actually ends.
        // We re-arm via asyncAfter (not the completion handler thread) so we
        // don't starve URLSession's delegate queue and prevent it from
        // delivering the Begin/Turn frames.
        if WebSocketErrorFilter.shouldIgnore(error) {
          DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.receiveMessages()
          }
          return
        }
        if self.retryWithFallbackEndpointIfNeeded(after: error) { return }
        self.logger.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
        self.currentOnError()?(error)
      }
    }
  }

  private func retryWithFallbackEndpointIfNeeded(after error: Error) -> Bool {
    var taskToCancel: URLSessionWebSocketTask?
    var fallback: AssemblyAIStreamingEndpoint = .global
    let shouldRetry = withStateLock { () -> Bool in
      guard
        !isStopping,
        !hasAttemptedHostFallback,
        !sessionDidBegin
      else {
        return false
      }
      hasAttemptedHostFallback = true
      fallback = (currentEndpointHost == .europe) ? .global : .europe
      currentEndpointHost = fallback
      taskToCancel = webSocketTask
      webSocketTask = nil
      return true
    }
    guard shouldRetry else { return false }

    let detail = error.localizedDescription
    let host = fallback.rawValue
    logger.warning(
      // swiftlint:disable:next line_length
      "AssemblyAI endpoint failed before session begin (\(detail, privacy: .public)); retrying \(host, privacy: .public)"
    )
    taskToCancel?.cancel(with: .goingAway, reason: nil)
    connectWebSocket(using: fallback)
    return true
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
    logger.info("AssemblyAI WS frame received (\(json.count) bytes)")
    guard let data = json.data(using: .utf8) else { return }

    do {
      let envelope = try JSONDecoder().decode(AssemblyAIStreamEnvelope.self, from: data)
      // Keep accepting the typeless Turn frames returned by older v3 model
      // snapshots while Universal-3.5 Pro returns the documented `type` field.
      let resolvedType = envelope.type ?? (envelope.turn_order != nil ? "Turn" : "")
      switch resolvedType {
      case "Turn":
        let turn = try JSONDecoder().decode(AssemblyAITurnResponse.self, from: data)
        currentOnTranscript()?(turn)
      case "Begin":
        withStateLock {
          sessionDidBegin = true
        }
        logger.info("AssemblyAI session started — \(json.prefix(200), privacy: .public)")
        flushPreBeginAudio()
      case "Termination":
        logger.info("AssemblyAI session terminated by server")
        if let task = currentWebSocketTask() {
          completeTermination(for: task)
        }
      case "SpeechStarted":
        break
      case "Error":
        // AssemblyAI sends an Error text frame just before closing with code 3006/4xxx.
        // Surface it at .info so users can capture it from `log show` filters.
        logger.error("AssemblyAI server Error frame: \(json.prefix(500), privacy: .public)")
      case "":
        // Unknown / typeless. Could be diagnostic text from server.
        logger.info("AssemblyAI typeless WS message: \(json.prefix(500), privacy: .public)")
      default:
        let body = json.prefix(500)
        logger.info("Unhandled AssemblyAI type=\(resolvedType, privacy: .public): \(body, privacy: .public)")
      }
    } catch {
      logger.debug("Failed to parse AssemblyAI response: \(error.localizedDescription)")
    }
  }
}
// swiftlint:enable type_body_length

extension AssemblyAILiveTranscriber {
  func waitForPendingSends(timeout: TimeInterval = 1.5) async {
    let sendGroup = pendingSendGroup
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        _ = sendGroup.wait(timeout: .now() + timeout)
        continuation.resume()
      }
    }
  }

  func updateConfiguration(_ config: [String: Any]) {
    guard let webSocketTask = currentWebSocketTask(), webSocketTask.state == .running else { return }
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

  /// Whether the AssemblyAI server has acknowledged the session with a
  /// `Begin` message. The post-stop finalisation budget is meaningless if
  /// the session never began (no audio reached the server, no Turn will
  /// ever be returned), so the controller can use this to skip the wait.
  func didReceiveBegin() -> Bool {
    withStateLock { sessionDidBegin }
  }
}

private extension AssemblyAILiveTranscriber {
  func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  func currentWebSocketTask() -> URLSessionWebSocketTask? {
    withStateLock { webSocketTask }
  }

  func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  func currentOnError() -> ((Error) -> Void)? {
    withStateLock { onError }
  }

  func currentOnTranscript() -> ((AssemblyAITurnResponse) -> Void)? {
    withStateLock { onTranscript }
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

  init(session: URLSession = .shared) {
    self.session = session
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
      body["language_code"] = language.localeLanguageCode
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
    // Use the /v2/transcript endpoint with a lightweight GET, limited to 1 result,
    // just to validate auth.
    let url = baseURL.appendingPathComponent("transcript")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "limit", value: "1")]

    return await GETProbeAPIKeyValidator(
      url: components.url ?? url,
      headers: { ["Authorization": $0] },
      serviceName: "AssemblyAI",
      session: session
    ).validate(key)
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  // MARK: - Supported Models

  func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }

  /// Creates a live transcriber for streaming audio.
  func createLiveTranscriber(
    apiKey: String,
    sampleRate: Int = 16000,
    model: String = AssemblyAIModels.universal35ProStreamingID,
    keyterms: [String] = [],
    language: String? = nil
  ) -> AssemblyAILiveTranscriber {
    _ = model
    _ = language
    // Pass session: nil so AssemblyAILiveTranscriber builds its own dedicated
    // URLSession for the WebSocket; the REST `session` (URLSession.shared) has
    // shown intermittent ENOTCONN handshake failures for the wss upgrade.
    return AssemblyAILiveTranscriber(
      apiKey: apiKey,
      sampleRate: sampleRate,
      keyterms: keyterms,
      session: nil
    )
  }

  // MARK: - Private Helpers

  func mapSpeechModels(from model: String) -> [String] {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    let cleaned = name.replacingOccurrences(of: "-streaming", with: "")
    switch cleaned {
    case AssemblyAIModels.universal35ProAPIName, "universal-3-pro":
      return [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
    case AssemblyAIModels.universal2APIName:
      return [AssemblyAIModels.universal2APIName]
    default:
      return [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
    }
  }

}

// MARK: - Streaming Response Models

private struct AssemblyAIStreamEnvelope: Decodable {
  let type: String?
  // swiftlint:disable:next identifier_name
  let turn_order: Int?
}

struct AssemblyAITurnResponse: Decodable {
  let type: String?
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

// MARK: - WebSocket Diagnostic Delegate

private final class AssemblyAIWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
  var logger: Logger?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    logger?.info("AssemblyAI WS didOpen protocol=\(`protocol` ?? "<nil>", privacy: .public)")
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
    logger?.info(
      "AssemblyAI WS didClose code=\(closeCode.rawValue, privacy: .public) reason=\(reasonStr, privacy: .public)"
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error = error as NSError? {
      let domain = error.domain
      let code = error.code
      let desc = error.localizedDescription
      logger?.error(
        // swiftlint:disable:next line_length
        "AssemblyAI WS didComplete error domain=\(domain, privacy: .public) code=\(code, privacy: .public) desc=\(desc, privacy: .public)"
      )
    } else {
      logger?.info("AssemblyAI WS didComplete (no error)")
    }
  }

  func urlSession(
    _ session: URLSession,
    taskIsWaitingForConnectivity task: URLSessionTask
  ) {
    logger?.info("AssemblyAI WS waiting for connectivity")
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    logger?.info("AssemblyAI WS auth challenge: \(challenge.protectionSpace.authenticationMethod, privacy: .public)")
    completionHandler(.performDefaultHandling, nil)
  }
}

// MARK: - Error Types

enum AssemblyAIError: LocalizedError {
  case invalidURL
  case connectionFailed
  case sendFailed
  case missingAPIKey
  case streamingFailed(String)

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
    case .streamingFailed(let detail):
      return "AssemblyAI streaming failed: \(detail)"
    }
  }
}
