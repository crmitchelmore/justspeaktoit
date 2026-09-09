import Foundation

/// Cross-platform realtime client for xAI's dedicated speech-to-text endpoint.
///
/// Separate from `XAILiveClient`, which drives the Grok Voice realtime session
/// in transcription-only mode. This one speaks the `wss://api.x.ai/v1/stt`
/// protocol: binary PCM frames up, `transcript.partial` frames down, and one
/// `transcript.done` after `audio.done`.
///
/// The class owns the connection, the ready handshake, the bounded
/// finalisation and the frame dispatch; the frame shapes live in
/// `XAISpeechToTextEvent`.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
/// (read 2026-09-10).
public final class XAISpeechToTextLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    /// Chunk finals lock a span of speech that is never restated, so each one
    /// is a new segment.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `audio.done` flushes audio xAI has received but not yet transcribed, so
    /// a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true

    static let finishBudget: TimeInterval = 5
    private static let sendDrainBudget: TimeInterval = 1

    private let apiKey: String
    private let language: String?
    private let keywords: [String]
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let finishLock = NSLock()
    private let pendingSends = DispatchGroup()
    private let logger = SpeakLogger.logger(category: "XAISpeechToTextLiveClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isReady = false
    private var isStopping = false
    private var isFinishing = false
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    private var finishContinuation: CheckedContinuation<String?, Never>?

    let preroll: StreamingAudioPreroll

    public init(
        apiKey: String,
        language: String? = nil,
        keywords: [String] = [],
        sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.keywords = keywords
        self.sampleRate = XAISpeechToText.supportedSampleRates.contains(sampleRate) ? sampleRate : 24_000
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: self.sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !apiKey.isEmpty else {
            onError(StreamingClientError.missingAPIKey(provider: "xAI"))
            return
        }
        beginSession(onTranscript: onTranscript, onError: onError)
        connect()
    }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect()`; tests pair it with `ingest`.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            self.onTranscript = onTranscript
            self.onError = onError
            isReady = false
            isStopping = false
            isFinishing = false
            accumulated.reset()
            finishContinuation = nil
        }
        preroll.reset()
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it.
    func ingest(_ text: String) {
        handle(.string(text))
    }

    public func sendAudio(_ audioData: Data) {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isReady, !isStopping, !isFinishing,
                  let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else {
            // xAI requires `transcript.created` before audio, so anything the
            // user says during the handshake is held rather than dropped.
            if !isEnding { preroll.append(audioData) }
            return
        }
        send(audioData, on: task)
    }

    public func finishAndWait() async -> String? {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isFinishing = true
            return webSocketTask
        }
        guard let task else {
            stop()
            return fullTranscript()
        }
        let result = await awaitFinalTranscript { [weak self, weak task] in
            DispatchQueue.global().async {
                guard let self, let task else { return }
                self.flushPreroll(to: task)
                _ = self.pendingSends.wait(timeout: .now() + Self.sendDrainBudget)
                task.send(.string(#"{"type":"audio.done"}"#)) { [weak self] error in
                    guard let self, let error, !WebSocketErrorFilter.shouldIgnore(error) else { return }
                    self.logger.error("xAI audio.done send failed: \(error.localizedDescription)")
                    self.resolveFinish()
                }
            }
        }
        stop()
        return result
    }

    /// The bounded wait for `transcript.done`, resolved by that frame (the
    /// common case, one round trip) or by the finish budget.
    ///
    /// `whenArmed` runs once the waiter is installed, so the `audio.done` frame
    /// cannot race its own completion handler; tests use it to deliver frames
    /// into an armed finish without a socket.
    func awaitFinalTranscript(
        budget: TimeInterval = XAISpeechToTextLiveClient.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        await withCheckedContinuation { continuation in
            finishLock.lock()
            finishContinuation = continuation
            finishLock.unlock()

            whenArmed()

            DispatchQueue.global().asyncAfter(deadline: .now() + budget) { [weak self] in
                self?.resolveFinish()
            }
        }
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isStopping = true
            isReady = false
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        preroll.reset()
        task?.cancel(with: .normalClosure, reason: nil)
        resolveFinish()
    }

    // MARK: - Connection

    /// `wss://api.x.ai/v1/stt` with the session configured entirely by query
    /// items — there is no start message and no `model` parameter.
    static func webSocketURL(
        sampleRate: Int,
        language: String?,
        keywords: [String] = []
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = XAISpeechToText.webSocketHost
        components.path = XAISpeechToText.webSocketPath
        var items = [
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "interim_results", value: "true")
        ]
        if let code = XAISpeechToText.languageCode(for: language) {
            items.append(URLQueryItem(name: "language", value: code))
        }
        // Repeated `keyterm` items, which is how the service takes a list.
        items += XAISpeechToText.boundedKeyterms(keywords).map {
            URLQueryItem(name: "keyterm", value: $0)
        }
        components.queryItems = items
        return components.url
    }

    private func connect() {
        guard let url = Self.webSocketURL(
            sampleRate: sampleRate, language: language, keywords: keywords
        ) else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let published = withStateLock { () -> Bool in
            guard !isStopping, !isFinishing else { return false }
            isReady = false
            webSocketTask = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        receiveMessages(on: task)
    }

    private func receiveMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if self.isCurrent(task) { self.receiveMessages(on: task) }
            case .failure(let error):
                self.handleTransportFailure(error)
            }
        }
    }

    /// Only an explicit `error` frame ends the session. An unrecognised frame —
    /// a keepalive, or a field added upstream — is ignored, matching every
    /// other shared client, because it must never end a live recording.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = XAISpeechToTextEvent(object: object) else { return }

        switch event {
        case .created:
            withStateLock { isReady = true }
            if let task = currentTask() { flushPreroll(to: task) }
        case .partial(let text, let isFinal, _, let eventID):
            handlePartial(text: text, isFinal: isFinal, eventID: eventID)
        case .done(let text):
            handleDone(text: text)
        case .failure(let message):
            fail(Self.error(fromServerMessage: message))
        }
    }

    private func handlePartial(text: String, isFinal: Bool, eventID: String?) {
        guard isFinal else {
            currentOnTranscript()?(text, false)
            return
        }
        let isNew = withStateLock { () -> Bool in
            let before = accumulated.text
            accumulated.append(final: text, eventID: eventID)
            return accumulated.text != before
        }
        if isNew { currentOnTranscript()?(text, true) }
    }

    /// `transcript.done` is authoritative for the whole session, so it replaces
    /// the folded chunk finals rather than appending to them, and it releases a
    /// waiting `finishAndWait()` immediately.
    private func handleDone(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            withStateLock { accumulated.replace(with: trimmed) }
        }
        if resolveFinish() {
            // Consumed by finishAndWait(), which returns the whole transcript;
            // delivering it again would double it for callers that append.
            return
        }
        if !trimmed.isEmpty { currentOnTranscript()?(trimmed, true) }
    }

    private func handleTransportFailure(_ error: Error) {
        if isEnding || WebSocketErrorFilter.shouldIgnore(error) {
            resolveFinish()
            return
        }
        fail(mapConnectionError(error))
    }

    private func fail(_ error: Error) {
        let callback = withStateLock { () -> ((Error) -> Void)? in
            guard !isStopping else { return nil }
            isStopping = true
            isReady = false
            let callback = onError
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            return callback
        }
        callback?(error)
        resolveFinish()
    }

    private func send(_ audio: Data, on task: URLSessionWebSocketTask) {
        pendingSends.enter()
        task.send(.data(audio)) { [weak self] error in
            guard let self else { return }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.handleTransportFailure(error)
            }
        }
    }

    private func flushPreroll(to task: URLSessionWebSocketTask) {
        for chunk in preroll.drain() { send(chunk, on: task) }
    }

    @discardableResult
    private func resolveFinish() -> Bool {
        finishLock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: fullTranscript())
        return true
    }

    static func error(fromServerMessage message: String) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("api key")
            || lowered.contains("forbidden") || lowered.contains("401")
            || lowered.contains("403") {
            return StreamingClientError.invalidAPIKey(provider: "xAI")
        }
        if lowered.contains("credit") || lowered.contains("quota")
            || lowered.contains("balance") {
            return XAISpeechToTextError.quotaExceeded(message: message)
        }
        if lowered.contains("rate limit") || lowered.contains("429") {
            return XAISpeechToTextError.rateLimited(message: message)
        }
        return XAISpeechToTextError.server(message: message)
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "xAI")
        }
        return error
    }

    /// Whether `transcript.created` has arrived and the socket accepts audio.
    var isSessionReady: Bool { withStateLock { isReady } }

    private var isEnding: Bool { withStateLock { isStopping || isFinishing } }
    private func isCurrent(_ task: URLSessionWebSocketTask) -> Bool {
        withStateLock { webSocketTask === task }
    }
    private func currentTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
    private func fullTranscript() -> String? { withStateLock { accumulated.transcriptOrNil } }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
