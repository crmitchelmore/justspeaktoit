import AVFoundation
import Foundation
import SpeakCore
import os.log

// MARK: - OpenAI Realtime Live Transcriber

// swiftlint:disable file_length type_body_length

/// Streams microphone audio to OpenAI's Realtime API in transcription mode and
/// emits incremental + final transcripts.
///
/// Endpoint: `wss://api.openai.com/v1/realtime?intent=transcription`.
/// Audio is sent as JSON text frames containing base64 PCM16 (mono, 24 kHz by
/// default). On stop we send `input_audio_buffer.commit` to force the server
/// to finalise the in-flight buffer, then close the socket once the
/// `…transcription.completed` event arrives (or the controller's
/// `postStopFinalizeBudget` elapses).
final class OpenAIRealtimeLiveTranscriber: @unchecked Sendable {
  enum Event {
    case sessionCreated
    case sessionReady
    case delta(String, itemId: String)
    case completed(String, itemId: String)
  }

  private let apiKey: String
  private let model: String
  private let language: String?
  private let prompt: String?
  private let sampleRate: Int
  private let session: URLSession
  private let logger = Logger(subsystem: "com.speak.app", category: "OpenAIRealtimeLiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()

  private var webSocketTask: URLSessionWebSocketTask?
  private var onEvent: ((Event) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping: Bool = false
  /// The OpenAI Realtime session is "ready" only after we receive
  /// `transcription_session.updated` — that's the acknowledgement of *our*
  /// `transcription_session.update` config, so we know `turn_detection`,
  /// language, prompt etc are applied. `transcription_session.created` can
  /// arrive before our update is acknowledged and the server still has its
  /// default config, which is why we deliberately do not mark ready on
  /// `.created`.
  private var sessionReady: Bool = false
  private var readyWaitTokens: [WaitToken] = []
  private var preReadyAudioBuffer: [Data] = []
  private static let preReadyAudioByteLimit = 24_000 * 2 * 5 // 5s of 24 kHz PCM16

  private let ownsSession: Bool

  init(
    apiKey: String,
    model: String,
    language: String?,
    prompt: String?,
    sampleRate: Int = 24_000,
    session: URLSession? = nil
  ) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.model = model
    self.language = language
    self.prompt = prompt
    self.sampleRate = sampleRate
    if let session {
      self.session = session
      self.ownsSession = false
    } else {
      let config = URLSessionConfiguration.default
      config.waitsForConnectivity = true
      config.timeoutIntervalForRequest = 30
      self.session = URLSession(configuration: config)
      self.ownsSession = true
    }
  }

  deinit {
    if ownsSession {
      session.invalidateAndCancel()
    }
  }

  // MARK: - Lifecycle

  func start(
    onEvent: @escaping (Event) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    withStateLock {
      isStopping = false
      sessionReady = false
      preReadyAudioBuffer = []
      self.onEvent = onEvent
      self.onError = onError
    }

    guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
      currentOnError()?(OpenAIRealtimeError.invalidURL)
      return
    }
    components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
    guard let url = components.url else {
      currentOnError()?(OpenAIRealtimeError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    // Required by the Realtime API while it's in beta.
    request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

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

    logger.info("OpenAI Realtime WebSocket connecting (model=\(self.model, privacy: .public))")
    receiveMessages()
    sendSessionUpdate()
  }

  func sendAudio(_ pcm16Data: Data) {
    // Decide "send now" vs "buffer until ready" inside a single critical
    // section to avoid a race where a flush triggered by .sessionReady can
    // run between an outer readiness check and an append, stranding the
    // newly-appended frame in preReadyAudioBuffer.
    let taskToSend: URLSessionWebSocketTask? = withStateLock {
      guard let task = webSocketTask, task.state == .running else { return nil }
      if sessionReady {
        return task
      }
      preReadyAudioBuffer.append(pcm16Data)
      var totalBytes = preReadyAudioBuffer.reduce(0) { $0 + $1.count }
      while totalBytes > Self.preReadyAudioByteLimit, !preReadyAudioBuffer.isEmpty {
        totalBytes -= preReadyAudioBuffer.removeFirst().count
      }
      return nil
    }
    if let taskToSend {
      sendAudioFrame(pcm16Data, on: taskToSend)
    }
  }

  /// Sends `input_audio_buffer.commit` which forces the server to finalise
  /// the buffered audio as a single conversation item — the equivalent of
  /// AssemblyAI's `ForceEndpoint`.
  ///
  /// The send completion is tracked via `pendingSendGroup` so callers can
  /// await it through `waitForPendingSends()` before starting any
  /// "wait for the final transcript" budget.
  func commitInputBuffer() {
    let task = withStateLock { webSocketTask }
    guard let task, task.state == .running else { return }
    let json = #"{"type":"input_audio_buffer.commit"}"#
    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.string(json)) { [weak self] error in
      defer { sendGroup.leave() }
      if let error, let self, !self.isStoppingState() {
        self.logger.error("Failed to commit input buffer: \(error.localizedDescription)")
        // Surface this — without it, a failed commit can leave callers
        // waiting indefinitely for a final transcript that will never come.
        self.currentOnError()?(error)
      }
    }
  }

  /// Awaits `transcription_session.updated`, the acknowledgement of our
  /// session config. Returns `true` if ready within the timeout, `false`
  /// otherwise. Used by the controller's stop path so a quick
  /// stop-after-start doesn't commit an empty server-side buffer.
  func awaitSessionReady(timeout: TimeInterval) async -> Bool {
    if withStateLock({ sessionReady }) { return true }

    let token = WaitToken()
    let alreadyReady: Bool = withStateLock {
      if sessionReady { return true }
      readyWaitTokens.append(token)
      return false
    }
    if alreadyReady { return true }

    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
      token.signal(false)
    }
    return await token.wait()
  }

  func stop() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      guard !isStopping else { return nil }
      isStopping = true
      return webSocketTask
    }

    guard let task, task.state == .running else { return }

    // The actual "wait for the final completed event" gate is enforced by the
    // controller's `postStopFinalizeBudget`, mirroring the AssemblyAI pattern.
    // Here we just close the socket; any in-flight `.completed` events will
    // race against the cancellation, and the controller will resume early
    // when `.completed` arrives.
    task.cancel(with: .normalClosure, reason: nil)
    withStateLock {
      if webSocketTask === task {
        webSocketTask = nil
      }
    }
    logger.info("OpenAI Realtime WebSocket connection closed")
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

  // MARK: - Outbound

  private func sendSessionUpdate() {
    let task = withStateLock { webSocketTask }
    guard let task else { return }

    var transcription: [String: Any] = ["model": model]
    if let language, !language.isEmpty {
      transcription["language"] = language
    }
    if let prompt, !prompt.isEmpty, OpenAIRealtimeLiveTranscriber.modelSupportsPrompt(model) {
      transcription["prompt"] = prompt
    }

    // `turn_detection: null` keeps the session push-to-talk: the server won't
    // auto-finalise on silence; we explicitly commit on stop. This mirrors
    // the AssemblyAI / Deepgram UX where the user controls the boundaries.
    let payload: [String: Any] = [
      "type": "transcription_session.update",
      "session": [
        "input_audio_format": "pcm16",
        "input_audio_transcription": transcription,
        "input_audio_noise_reduction": ["type": "near_field"],
        "turn_detection": NSNull()
      ]
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else {
      currentOnError()?(OpenAIRealtimeError.encodingFailed)
      return
    }

    task.send(.string(json)) { [weak self] error in
      if let error, let self, !self.isStoppingState() {
        self.logger.error("Failed to send session.update: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  private func sendAudioFrame(_ pcm16Data: Data, on task: URLSessionWebSocketTask) {
    let base64 = pcm16Data.base64EncodedString()
    let payload: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": base64
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return }

    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.string(json)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      if let error, !self.isStoppingState(), !self.shouldIgnoreSocketError(error) {
        self.logger.error("Failed to send audio: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  private func flushPreReadyAudio() {
    let (task, frames) = withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
      let pending = preReadyAudioBuffer
      preReadyAudioBuffer = []
      return (webSocketTask, pending)
    }
    guard let task, task.state == .running, !frames.isEmpty else { return }
    logger.info("Flushing \(frames.count) pre-ready OpenAI Realtime audio frames")
    for frame in frames {
      sendAudioFrame(frame, on: task)
    }
  }

  // MARK: - Inbound

  private func receiveMessages() {
    guard let task = withStateLock({ webSocketTask }) else { return }
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveMessages()
      case .failure(let error):
        if self.isStoppingState() { return }
        if self.shouldIgnoreSocketError(error) {
          // ENOTCONN / "Socket is not connected" is terminal — a
          // URLSessionWebSocketTask cannot be reused for receiving once
          // disconnected. Stop the receive loop instead of spinning every
          // 10 ms; higher-level reconnect logic (or stop()) is responsible
          // for replacing the task.
          self.logger.info("WebSocket receive loop ending (socket disconnected)")
          return
        }
        self.logger.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
        self.currentOnError()?(error)
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .string(let text):
      OpenAIRealtimeEventParser.parse(text, logger: logger).forEach(dispatch)
    case .data(let data):
      if let text = String(data: data, encoding: .utf8) {
        OpenAIRealtimeEventParser.parse(text, logger: logger).forEach(dispatch)
      }
    @unknown default:
      break
    }
  }

  private func dispatch(_ outcome: OpenAIRealtimeEventParser.ParsedOutcome) {
    switch outcome {
    case .event(let event):
      if case .sessionReady = event {
        let tokensToFire: [WaitToken] = withStateLock {
          sessionReady = true
          let tokens = readyWaitTokens
          readyWaitTokens.removeAll()
          return tokens
        }
        for token in tokensToFire {
          token.signal(true)
        }
        flushPreReadyAudio()
      }
      currentOnEvent()?(event)
    case .error(let error):
      currentOnError()?(error)
    case .ignored:
      break
    }
  }
}
// swiftlint:enable type_body_length

/// Lightweight one-shot async latch. The first `signal(_:)` resolves any
/// pending `wait()` and is idempotent thereafter.
private final class WaitToken: @unchecked Sendable {
  private let lock = NSLock()
  private var resolved: Bool = false
  private var value: Bool = false
  private var continuation: CheckedContinuation<Bool, Never>?

  func signal(_ value: Bool) {
    let cont: CheckedContinuation<Bool, Never>?
    let resolvedValue: Bool
    lock.lock()
    if resolved {
      lock.unlock()
      return
    }
    resolved = true
    self.value = value
    cont = continuation
    continuation = nil
    resolvedValue = value
    lock.unlock()
    cont?.resume(returning: resolvedValue)
  }

  func wait() async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      lock.lock()
      if resolved {
        let resolvedValue = value
        lock.unlock()
        cont.resume(returning: resolvedValue)
        return
      }
      continuation = cont
      lock.unlock()
    }
  }
}

// MARK: - Locking helpers

private extension OpenAIRealtimeLiveTranscriber {
  func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  func currentOnEvent() -> ((Event) -> Void)? {
    withStateLock { onEvent }
  }

  func currentOnError() -> ((Error) -> Void)? {
    withStateLock { onError }
  }

  func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  func shouldIgnoreSocketError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
    if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
      return true
    }
    return false
  }
}

// MARK: - Event Parser (testable)

/// Pure-function parser for OpenAI Realtime JSON events. Extracted so it can
/// be exercised directly in unit tests without spinning up a WebSocket.
enum OpenAIRealtimeEventParser {
  enum ParsedOutcome {
    case event(OpenAIRealtimeLiveTranscriber.Event)
    case error(Error)
    case ignored
  }

  static func parse(_ json: String, logger: Logger? = nil) -> [ParsedOutcome] {
    guard let data = json.data(using: .utf8) else { return [] }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    guard let type = object["type"] as? String else { return [] }

    switch type {
    case "transcription_session.created":
      // `created` confirms the socket is open with default config; we still
      // need to wait for `updated` (the ack of *our* session.update) before
      // sending audio.
      return [.event(.sessionCreated)]
    case "transcription_session.updated":
      return [.event(.sessionReady)]
    case "conversation.item.input_audio_transcription.delta":
      let delta = (object["delta"] as? String) ?? ""
      let itemId = (object["item_id"] as? String) ?? ""
      guard !delta.isEmpty else { return [.ignored] }
      return [.event(.delta(delta, itemId: itemId))]
    case "conversation.item.input_audio_transcription.completed":
      let transcript = (object["transcript"] as? String) ?? ""
      let itemId = (object["item_id"] as? String) ?? ""
      return [.event(.completed(transcript, itemId: itemId))]
    case "error":
      let payload = object["error"] as? [String: Any]
      let message = (payload?["message"] as? String) ?? "Unknown error"
      let code = (payload?["code"] as? String) ?? "unknown"
      logger?.error("OpenAI Realtime error: code=\(code, privacy: .public) msg=\(message, privacy: .public)")
      return [.error(OpenAIRealtimeError.serverError(code: code, message: message))]
    default:
      logger?.debug("OpenAI Realtime ignored event type=\(type, privacy: .public)")
      return [.ignored]
    }
  }
}

// MARK: - Errors

enum OpenAIRealtimeError: LocalizedError {
  case invalidURL
  case missingAPIKey
  case encodingFailed
  case serverError(code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Failed to construct OpenAI Realtime WebSocket URL"
    case .missingAPIKey:
      return "OpenAI API key is missing. Add it in Settings → Models / Keys."
    case .encodingFailed:
      return "Failed to encode OpenAI Realtime payload"
    case .serverError(let code, let message):
      return "OpenAI Realtime error (\(code)): \(message)"
    }
  }
}

// MARK: - Provider (factory)

/// Lightweight factory for `OpenAIRealtimeLiveTranscriber`. Unlike the
/// AssemblyAI / ElevenLabs / OpenAI batch providers, this isn't a
/// `TranscriptionProvider` because it doesn't expose a batch transcription
/// path — `OpenAITranscriptionProvider` already covers Whisper batch.
struct OpenAIRealtimeTranscriptionProvider {
  func createLiveTranscriber(
    apiKey: String,
    model: String,
    language: String?,
    prompt: String?,
    sampleRate: Int = 24_000,
    session: URLSession? = nil
  ) -> OpenAIRealtimeLiveTranscriber {
    OpenAIRealtimeLiveTranscriber(
      apiKey: apiKey,
      model: model,
      language: language,
      prompt: prompt,
      sampleRate: sampleRate,
      session: session
    )
  }

  /// Translates an `openai/...-streaming` model id into the bare model name
  /// expected by the Realtime API.
  static func realtimeModelName(from catalogID: String) -> String {
    let suffix = catalogID.split(separator: "/").last.map(String.init) ?? catalogID
    return suffix.replacingOccurrences(of: "-streaming", with: "")
  }
}

extension OpenAIRealtimeLiveTranscriber {
  /// OpenAI Realtime only accepts `input_audio_transcription.prompt` for the
  /// GPT-4o transcription models. `gpt-realtime-whisper` (Whisper-1) rejects
  /// the parameter with `invalid_value`. Returning false here means the
  /// provider silently drops the prompt for unsupported models rather than
  /// failing the whole session.
  static func modelSupportsPrompt(_ realtimeModel: String) -> Bool {
    let name = realtimeModel.lowercased()
    return name.hasPrefix("gpt-4o-transcribe") || name.hasPrefix("gpt-4o-mini-transcribe")
  }
}

// swiftlint:enable file_length
