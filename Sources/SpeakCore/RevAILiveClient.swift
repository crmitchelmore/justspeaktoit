import Foundation

/// Cross-platform client for Rev AI's streaming speech-to-text WebSocket.
///
/// Binary PCM frames go up; `connected`, `partial` and `final` JSON text frames
/// come back. `EOS` — a literal, case-sensitive text frame — commits the tail,
/// after which Rev AI sends one last hypothesis and closes. Rev AI rejects
/// audio before its `connected` frame, so leading capture is held in
/// `StreamingAudioPreroll` and replayed (issue #641).
///
/// Contract: https://docs.rev.ai/api/streaming/requests and
/// https://docs.rev.ai/api/streaming/responses (read 2026-09-10).
public final class RevAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    /// Rev AI documents that a `final` hypothesis covers a section of audio
    /// whose output "will no longer change", and the next `partial` starts a
    /// fresh segment — so each final is standalone.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EOS` makes Rev AI transcribe audio it has received but not yet
    /// finalised, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true

    /// The literal end-of-stream token. Rev AI closes the socket with
    /// `1007 Invalid Payload` for any other text frame — including `eos` and
    /// `Eos` — and a real WebSocket close frame loses the final hypothesis.
    static let endOfStreamToken = "EOS"

    private static let sendDrainBudget: TimeInterval = 1

    private let accessToken: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let finishLock = NSLock()
    private let pendingSends = DispatchGroup()
    private let logger = SpeakLogger.logger(category: "RevAILiveClient")

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
        accessToken: String,
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !accessToken.isEmpty else {
            onError(StreamingClientError.missingAPIKey(provider: "Rev.ai"))
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
        guard !audioData.isEmpty else { return }
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isReady, !isStopping, !isFinishing,
                  let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else {
            // Rev AI rejects audio before its `connected` frame, so the user's
            // opening words are held rather than dropped. Bursting the backlog
            // afterwards is explicitly supported: the service transcribes
            // faster than real time and bills max(stream, audio) duration.
            if !isEnding { preroll.append(audioData) }
            return
        }
        send(audioData, on: task)
    }

    public func finishAndWait() async -> String? {
        let (task, wasReady) = withStateLock { () -> (URLSessionWebSocketTask?, Bool) in
            isFinishing = true
            return (webSocketTask, isReady)
        }
        // Without `connected` there is no session to commit, and an `EOS` on a
        // socket Rev AI has not acknowledged would be rejected.
        guard let task, wasReady else {
            stop()
            return fullTranscript()
        }
        let result = await awaitFinalTranscript { [weak self, weak task] in
            DispatchQueue.global().async { [weak self, weak task] in
                guard let self, let task else { return }
                self.flushPreroll(to: task)
                _ = self.pendingSends.wait(timeout: .now() + Self.sendDrainBudget)
                task.send(.string(Self.endOfStreamToken)) { [weak self] error in
                    guard let self, let error, !WebSocketErrorFilter.shouldIgnore(error) else { return }
                    self.logger.error("Rev.ai EOS send failed: \(error.localizedDescription)")
                    self.resolveFinish()
                }
            }
        }
        stop()
        return result
    }

    /// The bounded wait for the trailing hypothesis. Rev AI answers `EOS` with
    /// one last `final` and *then* closes the socket, so the close is the
    /// completion signal; the budget is the fallback.
    ///
    /// `whenArmed` runs once the waiter is installed, so the `EOS` frame cannot
    /// race its own completion handler; tests use it to deliver frames into an
    /// armed finish without a socket.
    func awaitFinalTranscript(
        budget: TimeInterval = RevAIStreaming.finishBudget,
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

    /// Rev AI authenticates the streaming socket with an `access_token` query
    /// parameter; `Authorization: Bearer` is documented only for its two HTTP
    /// endpoints, so the header is deliberately not sent here.
    static func webSocketURL(
        accessToken: String,
        sampleRate: Int,
        language: String?,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = RevAIStreaming.webSocketHost
        components.path = RevAIStreaming.webSocketPath
        var items = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(
                name: "content_type", value: RevAIStreaming.rawPCMContentType(sampleRate: sampleRate)
            ),
            URLQueryItem(name: "transcriber", value: RevAIStreaming.transcriber)
        ]
        if let code = RevAIStreaming.languageCode(
            for: language, systemLocaleIdentifier: systemLocaleIdentifier
        ) {
            items.append(URLQueryItem(name: "language", value: code))
        }
        components.queryItems = items
        return components.url
    }

    private func connect() {
        guard let url = Self.webSocketURL(
            accessToken: accessToken, sampleRate: sampleRate, language: language
        ) else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }
        let task = session.webSocketTask(with: url)
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
                self.handleTransportFailure(error, closeCode: task.closeCode)
            }
        }
    }

    /// Rev AI has exactly three frame types; anything else decodes to `nil` in
    /// `RevAIStreamingEvent` and is ignored, because an unrecognised frame must
    /// never end a live recording.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let event = RevAIStreamingEvent(message: message) else { return }

        switch event {
        case .connected:
            withStateLock { isReady = true }
            if let task = currentTask() { flushPreroll(to: task) }
        case .partial(let text):
            currentOnTranscript()?(text, false)
        case .final(let text):
            withStateLock { accumulated.append(final: text) }
            currentOnTranscript()?(text, true)
        }
    }

    private func handleTransportFailure(_ error: Error, closeCode: URLSessionWebSocketTask.CloseCode) {
        // Rev AI reports every terminal condition as a 4xxx close code, so the
        // code is authoritative even while finishing: a session that ran out of
        // credit mid-stream must still surface, not be swallowed as a stop.
        if let mapped = RevAIStreamingError.forCloseCode(closeCode.rawValue) {
            fail(mapped)
            return
        }
        if isEnding || WebSocketErrorFilter.shouldIgnore(error) {
            resolveFinish()
            return
        }
        fail(error)
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
        task.send(.data(audio)) { [weak self, weak task] error in
            guard let self else { return }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.handleTransportFailure(error, closeCode: task?.closeCode ?? .invalid)
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

    /// Whether the `connected` frame has arrived and the socket accepts audio.
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
