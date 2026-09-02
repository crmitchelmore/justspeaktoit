// The client owns connection, setup gating, reconnect and bounded
// finalisation; the frame shaping and event decoding live in
// GeminiLiveProtocol.swift.
// swiftlint:disable file_length
import Foundation
import os

/// Cross-platform Google Gemini 3.5 Transcribe Live streaming client.
///
/// Speaks the Gemini Live API's `BidiGenerateContent` WebSocket in
/// transcription-only mode: `responseModalities: ["TEXT"]`, server-side voice
/// activity detection, and no model response is ever requested, so no assistant
/// audio or text is generated or billed.
///
/// Audio is 16 kHz mono little-endian PCM16 sent base64-encoded inside
/// `realtimeInput.audio`, as the WebSocket transport documents. Both macOS and
/// iOS feed it through their own capture layers.
///
/// Never logs audio, transcript text or the API key.
public final class GeminiLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Final shape: each `inputTranscription` carries one finalised utterance,
    /// so finals append rather than replace (issue #700).
    public let finalShape: TranscriptFinalShape = .standaloneSegments

    /// `audioStreamEnd` genuinely flushes audio the server has received but not
    /// yet transcribed, so a stop must always drain.
    public let finishFlushesBufferedAudio = true

    /// One absolute budget for the whole finalisation: the pending-audio flush,
    /// the `audioStreamEnd` send and the wait for the trailing final all draw
    /// on the same deadline instead of starting independent timers.
    static let finishBudgetSeconds: TimeInterval = 4
    private static let pendingSendStageCapSeconds: TimeInterval = 1.5
    /// Audio held while the setup handshake is in flight, capped at five
    /// seconds of PCM16 so a stalled handshake cannot grow without bound.
    private static let preSetupByteLimit = 16_000 * 2 * 5
    /// The Live API caps a session at ten minutes and announces the close with
    /// `goAway`; a bounded reconnect keeps long dictation going across that
    /// boundary without ever becoming a retry storm.
    private static let maximumReconnectAttempts = 3
    private static let reconnectDelaySeconds: TimeInterval = 0.25

    private let apiKey: String
    private let model: String
    private let language: String?
    private let customVocabulary: [String]
    private let mode: GeminiTranscriptionMode
    private let sampleRate: Int
    private let session: URLSession
    private let logger = SpeakLogger.logger(category: "GeminiLiveClient")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var pendingAudio: [Data] = []
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    private var isConfigured = false
    private var isStopping = false
    private var didReceiveFinalSinceFinish = false
    private var reconnectAttempts = 0
    private var finishContinuation: CheckedContinuation<String?, Never>?

    public init(
        apiKey: String,
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String? = nil,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.customVocabulary = customVocabulary
        self.mode = mode
        self.sampleRate = sampleRate
        self.session = session
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.beginSession(onTranscript: onTranscript, onError: onError)
        self.connect()
    }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect()`; tests pair it with `ingest` to
    /// drive the receive path offline.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.withStateLock {
            self.isStopping = false
            self.isConfigured = false
            self.didReceiveFinalSinceFinish = false
            self.reconnectAttempts = 0
            self.pendingAudio = []
            self.accumulated.reset()
            self.finishContinuation = nil
            self.onTranscript = onTranscript
            self.onError = onError
        }
    }

    public func sendAudio(_ audioData: Data) {
        let task = self.withStateLock { () -> URLSessionWebSocketTask? in
            guard !self.isStopping else { return nil }
            guard self.isConfigured, let task = self.webSocketTask, task.state == .running else {
                self.pendingAudio.append(audioData)
                self.trimPendingAudioLocked()
                return nil
            }
            return task
        }
        guard let task else { return }
        self.sendAudioFrame(audioData, on: task)
    }

    /// Commits the input buffer with `audioStreamEnd` and waits (bounded) for
    /// the trailing `inputTranscription`.
    ///
    /// Returns the **full transcript for the session**, never just the last
    /// utterance: Gemini's finals are segment-shaped, so they are folded
    /// through `TranscriptAccumulator` exactly as the protocol requires.
    public func finishAndWait() async -> String? {
        let task = self.withStateLock { () -> URLSessionWebSocketTask? in
            guard !self.isStopping else { return nil }
            self.isStopping = true
            self.didReceiveFinalSinceFinish = false
            return self.webSocketTask
        }
        guard let task else { return self.currentTranscript() }

        let deadline = Date().addingTimeInterval(Self.finishBudgetSeconds)
        self.flushPendingAudio(on: task)
        await self.waitForPendingSends(deadline: deadline)
        self.send(.string(Self.audioStreamEndJSON()), on: task)

        let transcript = await self.waitForTrailingFinal(deadline: deadline)
        self.close(task)
        self.resumeFinishIfNeeded(with: nil)
        return transcript ?? self.currentTranscript()
    }

    public func stop() {
        let task = self.withStateLock { () -> URLSessionWebSocketTask? in
            guard !self.isStopping else { return nil }
            self.isStopping = true
            return self.webSocketTask
        }
        if let task { self.close(task) }
        self.resumeFinishIfNeeded(with: self.currentTranscript())
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it instead of
    /// opening a socket.
    func ingest(_ text: String) {
        self.handleMessage(.string(text))
    }
}

// MARK: - Connection

private extension GeminiLiveClient {
    func connect() {
        guard let url = Self.webSocketURL(apiKey: self.apiKey) else {
            self.currentOnError()?(
                StreamingClientError.missingAPIKey(
                    provider: GeminiTranscribeModels.providerDisplayName
                )
            )
            return
        }
        guard let setup = Self.setupMessageJSON(
            model: self.model,
            language: self.language,
            customVocabulary: self.customVocabulary,
            mode: self.mode
        ) else {
            self.currentOnError()?(GeminiLiveError.encodingFailed)
            return
        }

        let task = self.session.webSocketTask(with: url)
        let proceed = self.withStateLock { () -> Bool in
            guard !self.isStopping else { return false }
            self.webSocketTask = task
            self.isConfigured = false
            return true
        }
        guard proceed else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        self.logger.info("Gemini Live WebSocket connecting (model=\(self.model, privacy: .public))")
        self.receiveMessages(on: task)
        self.send(.string(setup), on: task)
    }

    func receiveMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                // Guard by task identity so a frame from a retired socket can
                // never restart the loop on the current one.
                guard self.currentWebSocketTask() === task else { return }
                self.receiveMessages(on: task)
            case .failure(let error):
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
                guard self.currentWebSocketTask() === task else { return }
                if self.attemptReconnect(after: task) { return }
                self.currentOnError()?(self.mapTransportError(error))
                self.resumeFinishIfNeeded(with: self.currentTranscript())
            }
        }
    }

    /// Re-opens the session after a server-initiated close (`goAway`, or the
    /// documented ten-minute session cap). Returns `false` once the attempt
    /// budget is spent, so the caller surfaces the failure instead.
    func attemptReconnect(after task: URLSessionWebSocketTask) -> Bool {
        let shouldReconnect = self.withStateLock { () -> Bool in
            guard !self.isStopping else { return false }
            guard self.webSocketTask === task else { return false }
            guard self.reconnectAttempts < Self.maximumReconnectAttempts else { return false }
            self.reconnectAttempts += 1
            self.webSocketTask = nil
            self.isConfigured = false
            return true
        }
        guard shouldReconnect else { return false }
        task.cancel(with: .goingAway, reason: nil)
        let delay = Self.reconnectDelaySeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStoppingState() else { return }
            self.connect()
        }
        return true
    }
}

// MARK: - Events

private extension GeminiLiveClient {
    func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text else { return }

        if let event = Self.transcriptEvent(from: text) {
            self.handleTranscriptEvent(event)
            return
        }
        guard let signal = Self.serverSignal(from: text) else { return }
        self.handleSignal(signal)
    }

    func handleTranscriptEvent(_ event: GeminiLiveTranscriptEvent) {
        if event.isFinal {
            self.withStateLock {
                self.accumulated.append(final: event.text)
                self.didReceiveFinalSinceFinish = true
            }
        }
        self.currentOnTranscript()?(event.text, event.isFinal)
        if event.isFinal {
            self.resumeFinishIfNeeded(with: self.currentTranscript())
        }
    }

    func handleSignal(_ signal: GeminiLiveServerSignal) {
        switch signal {
        case .setupComplete:
            self.flushPendingAudioAfterSetup()
        case .turnComplete:
            // A turn can complete without a further transcription frame (for
            // example a silent tail), so release a waiting finish.
            self.resumeFinishIfNeeded(with: self.currentTranscript())
        case .goAway:
            self.handleGoAway()
        case .failure(let code, let status, let message):
            let error = Self.mapServerFailure(code: code, status: status, message: message)
            self.currentOnError()?(error)
            self.resumeFinishIfNeeded(with: self.currentTranscript())
        }
    }

    /// `goAway` announces a server-initiated close. Mid-session that is the
    /// ten-minute cap and the session is re-established; during finalisation it
    /// is the expected teardown and is left alone.
    func handleGoAway() {
        guard !self.isStoppingState() else {
            self.resumeFinishIfNeeded(with: self.currentTranscript())
            return
        }
        guard let task = self.currentWebSocketTask() else { return }
        if !self.attemptReconnect(after: task) {
            self.currentOnError()?(
                GeminiLiveError.server(
                    code: nil,
                    status: "GO_AWAY",
                    message: "The Gemini Live session ended and could not be re-established."
                )
            )
        }
    }

    func flushPendingAudioAfterSetup() {
        let (task, frames) = self.withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
            self.isConfigured = true
            self.reconnectAttempts = 0
            let frames = self.pendingAudio
            self.pendingAudio = []
            return (self.webSocketTask, frames)
        }
        guard let task, task.state == .running else { return }
        for frame in frames { self.sendAudioFrame(frame, on: task) }
    }
}

// MARK: - Sending

private extension GeminiLiveClient {
    func sendAudioFrame(_ audioData: Data, on task: URLSessionWebSocketTask) {
        guard let json = Self.audioChunkJSON(audioData, sampleRate: self.sampleRate) else {
            self.currentOnError()?(GeminiLiveError.encodingFailed)
            return
        }
        self.send(.string(json), on: task)
    }

    func send(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let group = self.pendingSendGroup
        group.enter()
        task.send(message) { [weak self] error in
            defer { group.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
            self.currentOnError()?(self.mapTransportError(error))
        }
    }

    func flushPendingAudio(on task: URLSessionWebSocketTask) {
        let frames = self.withStateLock { () -> [Data] in
            let frames = self.pendingAudio
            self.pendingAudio = []
            return frames
        }
        for frame in frames { self.sendAudioFrame(frame, on: task) }
    }

    func trimPendingAudioLocked() {
        var total = self.pendingAudio.reduce(0) { $0 + $1.count }
        while total > Self.preSetupByteLimit, !self.pendingAudio.isEmpty {
            total -= self.pendingAudio.removeFirst().count
        }
    }

    func waitForPendingSends(deadline: Date) async {
        let timeout = min(
            Self.pendingSendStageCapSeconds,
            max(0, deadline.timeIntervalSinceNow)
        )
        let group = self.pendingSendGroup
        await withCheckedContinuation { continuation in
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable () -> Void = {
                let shouldResume = didResume.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume()
            }
            group.notify(queue: .global()) { resumeOnce() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { resumeOnce() }
        }
    }

    func waitForTrailingFinal(deadline: Date) async -> String? {
        await withCheckedContinuation { continuation in
            let shouldWait = self.withStateLock { () -> Bool in
                guard !self.didReceiveFinalSinceFinish else { return false }
                guard self.finishContinuation == nil else { return false }
                self.finishContinuation = continuation
                return true
            }
            guard shouldWait else {
                continuation.resume(returning: self.currentTranscript())
                return
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self else { return }
                self.resumeFinishIfNeeded(with: self.currentTranscript())
            }
        }
    }

    func resumeFinishIfNeeded(with transcript: String?) {
        let continuation = self.withStateLock { () -> CheckedContinuation<String?, Never>? in
            let continuation = self.finishContinuation
            self.finishContinuation = nil
            return continuation
        }
        continuation?.resume(returning: transcript)
    }

    func close(_ task: URLSessionWebSocketTask) {
        let shouldClose = self.withStateLock { () -> Bool in
            guard self.webSocketTask === task else { return false }
            self.webSocketTask = nil
            self.isConfigured = false
            self.pendingAudio = []
            return true
        }
        if shouldClose {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}

// MARK: - State

private extension GeminiLiveClient {
    func mapTransportError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(
                provider: GeminiTranscribeModels.providerDisplayName
            )
        }
        if nsError.code == 429 || description.contains("429") {
            return GeminiLiveError.rateLimited(nsError.localizedDescription)
        }
        return error
    }

    func withStateLock<T>(_ block: () -> T) -> T {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return block()
    }

    func currentWebSocketTask() -> URLSessionWebSocketTask? { self.withStateLock { self.webSocketTask } }
    func isStoppingState() -> Bool { self.withStateLock { self.isStopping } }
    func currentOnTranscript() -> ((String, Bool) -> Void)? { self.withStateLock { self.onTranscript } }
    func currentOnError() -> ((Error) -> Void)? { self.withStateLock { self.onError } }
    func currentTranscript() -> String? { self.withStateLock { self.accumulated.transcriptOrNil } }
}
