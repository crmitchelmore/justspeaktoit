import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared realtime client for xAI's dedicated speech-to-text endpoint, used by
/// macOS, iOS and Windows.
///
/// Separate from `XAILiveClient`, which drives the Grok Voice realtime session
/// in transcription-only mode. This one speaks the `wss://api.x.ai/v1/stt`
/// protocol: the session is configured by the URL's query items (there is no
/// start message), binary PCM frames go up, `transcript.partial` frames come
/// down, and one `transcript.done` follows `audio.done`.
///
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows). PCM is admitted synchronously into a bounded queue and sent one
/// frame at a time once `transcript.created` has arrived; finalisation drains
/// the queue, sends `audio.done` and waits for `transcript.done` inside one
/// bounded budget. Frame shapes live in `XAISpeechToTextEvent`.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
/// (read 2026-09-22).
public final class XAISpeechToTextLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Chunk finals lock a span of speech that is never restated, so each one
    /// is a new segment.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `audio.done` flushes audio xAI has received but not yet transcribed, so
    /// a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// One deadline bounds a graceful finish: the handshake wait, the audio
    /// drain, `audio.done` and the `transcript.done` wait.
    static let finishBudget: TimeInterval = 5
    /// How long a graceful finish waits for `transcript.created` before giving
    /// up on the held capture. Inside `finishBudget`, so the caller's stop is
    /// still bounded by it.
    static let readyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// `transcript.created` must follow `start()` within this bound.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Queued frames are bounded by count as well as by the five-second byte budget.
    static let maximumQueuedFrames = 256

    private let apiKey: String
    private let language: String?
    private let keywords: [String]
    /// The rate the socket declares and the rate the caller's PCM must be
    /// encoded at. Exactly what the initializer was given: substituting a
    /// different one here would have the session declare a rate the audio does
    /// not have, which recognises badly and silently.
    public let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let queue = DispatchQueue(label: "XAISpeechToTextLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private(set) var run: XAISpeechToTextLiveRun
    /// The pre-start priming contract shared with the other clients: audio
    /// offered before `start()` is held here. Once a session starts, its
    /// bounded send queue holds connecting audio without silently evicting it.
    let preroll: StreamingAudioPreroll

    public convenience init(
        apiKey: String,
        language: String? = nil,
        keywords: [String] = [],
        sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, language: language, keywords: keywords, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String,
        language: String? = nil,
        keywords: [String] = [],
        sampleRate: Int = 24_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.keywords = keywords
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = XAISpeechToTextLiveRun(sampleRate: sampleRate)
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            let active = arm(onTranscript: onTranscript, onError: onError)
            guard !apiKey.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "xAI"), active)
                return
            }
            // An unsupported rate is refused rather than quietly replaced: the
            // caller encodes its PCM at the rate it asked for, so a substitution
            // here would declare one rate and send another.
            guard XAISpeechToText.supportedSampleRates.contains(sampleRate) else {
                fail(XAISpeechToTextError.unsupportedSampleRate(sampleRate), active)
                return
            }
            guard let request = Self.webSocketRequest(
                apiKey: apiKey, sampleRate: sampleRate, language: language, keywords: keywords
            ) else {
                fail(StreamingClientError.invalidURL, active)
                return
            }
            connect(active, request: request)
        }
    }

    /// Admission is synchronous and bounded: at most five seconds of PCM may be
    /// queued or in flight and at most `maximumQueuedFrames` frames may wait.
    /// Exceeding either is evidence that the transport has stopped working, or
    /// that `transcript.created` is not coming, and is reported instead of
    /// holding the recording without bound. Nothing leaves before
    /// `transcript.created`, because the service refuses audio sent earlier.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            if active.phase == .idle { preroll.append(audioData); return }
            guard active.phase == .connecting || active.phase == .active else { return }
            guard active.outgoing.count + (active.sending ? 1 : 0) < Self.maximumQueuedFrames,
                  active.budget.admit(audioData.count) else {
                fail(stalledError, active)
                return
            }
            active.outgoing.append(audioData)
            pump(active)
        }
    }

    /// Immediate teardown; `cancel()` is the same path. Text received so far
    /// stays available to `finishAndWait()`.
    public func stop() { synchronized { close(run) } }

    /// Drains every admitted frame, sends `audio.done` and waits for
    /// `transcript.done`, all inside `finishBudget`. The return value is the
    /// whole session transcript, so finals that arrive during the finish are
    /// folded into it and returned once rather than also delivered through
    /// `onTranscript`.
    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), active.connection != nil else {
                        if active === run { close(active) }
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    if Task.isCancelled {
                        close(active)
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    active.waiters.append(continuation)
                    beginFinish(active)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    // MARK: - Session seams

    /// Whether `transcript.created` has arrived and the session accepts audio.
    var isSessionReady: Bool { synchronized { isCurrent(run) && run.ready } }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect`; tests pair it with `ingest`.
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized { _ = arm(onTranscript: onTranscript, onError: onError) }
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it.
    func ingest(_ text: String) { synchronized { handle(Data(text.utf8), run) } }

    /// The bounded wait for `transcript.done`, resolved by that frame (the
    /// common case, one round trip) or by the budget.
    ///
    /// `whenArmed` runs once the waiter is installed, so a frame it delivers
    /// cannot race its own completion; tests use it to deliver frames into an
    /// armed finish without a socket. `finishAndWait()` is this wait plus the
    /// drain and `audio.done` sequencing.
    func awaitFinalTranscript(
        budget: TimeInterval = XAISpeechToTextLiveClient.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        let active = synchronized { run }
        return await withCheckedContinuation { continuation in
            let armed: Bool = synchronized {
                guard isCurrent(active) else { return false }
                active.waiters.append(continuation)
                after(budget, active) { client, active in client.close(active) }
                return true
            }
            guard armed else {
                continuation.resume(returning: active.transcript)
                return
            }
            whenArmed()
        }
    }

    // MARK: - Run lifecycle

    /// Replaces the current run with a fresh one whose callbacks are armed.
    private func arm(
        onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void
    ) -> XAISpeechToTextLiveRun {
        close(run)
        let active = XAISpeechToTextLiveRun(sampleRate: sampleRate)
        run = active
        active.onTranscript = onTranscript
        active.onError = onError
        active.phase = .connecting
        return active
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "xAI") }

    func fail(_ error: Error, _ active: XAISpeechToTextLiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        close(active)
        log("Session failed")
        // Publish the failure before finish returns. The run is already
        // detached, so the callback may start a replacement session safely.
        callback?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func close(_ active: XAISpeechToTextLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll(keepingCapacity: false)
        active.budget.reset()
        active.sending = false
        if active === run { preroll.reset() }
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        connection?.cancel()
        waiters.forEach { $0.resume(returning: transcript) }
        active.onTranscript = nil
        active.onError = nil
    }

    func isCurrent(_ active: XAISpeechToTextLiveRun) -> Bool { active === run && active.phase != .closed }

    func after(_ seconds: TimeInterval, _ active: XAISpeechToTextLiveRun,
               action: @escaping @Sendable (XAISpeechToTextLiveClient, XAISpeechToTextLiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    /// Lifecycle events only: never a key, a frame or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "XAISpeechToTextLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
