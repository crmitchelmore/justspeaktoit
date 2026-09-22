import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared OpenAI Realtime transcription client used by macOS, iOS and Windows.
///
/// One `?intent=transcription` socket per run. The GA `session.update` goes out
/// after the real handshake; PCM16 mono 24 kHz frames are admitted synchronously
/// into a bounded queue and sent one at a time once `session.updated` has
/// acknowledged the configuration. Finalisation drains the queue, commits the
/// buffer and waits for the committed item's completed transcript within the
/// model's finalise budget. The transport is injectable; framing, admission and
/// lifecycle stay here so the platforms cannot drift.
public final class OpenAIRealtimeLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Canonical per-item events for hosts that assemble transcripts themselves.
    /// `sessionCreated` is informational; only `sessionReady` permits audio.
    public enum Event: Equatable, Sendable {
        case sessionCreated
        case sessionReady
        case delta(String, itemId: String)
        case completed(String, itemId: String)
    }

    /// Every `onTranscript` delivery restates the whole session transcript in
    /// item order, so finals replace rather than append.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Handshake plus configuration acknowledgement must land within this bound.
    public static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    public static let sendDeadline: TimeInterval = 5
    /// Drain, commit and completion are bounded together during finalisation.
    public static let finishDeadline: TimeInterval = 8
    /// How long a finish keeps admitted audio while the acknowledgement is still pending.
    public static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// Queued frames are bounded by count as well as by the five-second byte budget.
    public static let maximumQueuedFrames = 256

    let apiKey: String
    let model: String
    let language: String?
    let prompt: String?
    let sampleRate: Int
    let finalizeBudget: TimeInterval
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let queue = DispatchQueue(label: "OpenAIRealtimeLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let ownedSession: URLSession?
    var run: OpenAIRealtimeLiveRun

    public convenience init(
        apiKey: String, model: String, language: String? = nil, prompt: String? = nil,
        sampleRate: Int = OpenAIRealtimeProtocol.sampleRate, session: URLSession? = nil
    ) {
        let transportSession: URLSession
        if let session { transportSession = session } else {
            let configuration = URLSessionConfiguration.default
            #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
            #endif
            configuration.timeoutIntervalForRequest = 30
            transportSession = URLSession(configuration: configuration)
        }
        self.init(
            apiKey: apiKey, model: model, language: language, prompt: prompt, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: transportSession, request: $0) },
            ownedSession: session == nil ? transportSession : nil
        )
    }

    public init(
        apiKey: String, model: String, language: String? = nil, prompt: String? = nil,
        sampleRate: Int = OpenAIRealtimeProtocol.sampleRate,
        finalizeBudget: TimeInterval? = nil,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        },
        ownedSession: URLSession? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.prompt = prompt
        self.sampleRate = sampleRate
        self.finalizeBudget = finalizeBudget ?? Self.finalizeBudget(forModel: model)
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.ownedSession = ownedSession
        self.run = OpenAIRealtimeLiveRun()
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        run.connection?.cancel()
        ownedSession?.invalidateAndCancel()
    }

    /// The catalogue's post-stop finalise budget for this model, so the shared
    /// client and the Apple controllers wait the same bounded time for the
    /// commit's completed event.
    public static func finalizeBudget(forModel model: String) -> TimeInterval {
        let apiName = OpenAITranscriptionModels.apiModelName(from: model)
        let budget = ModelCatalog.liveCapabilities(for: "openai/\(apiName)-streaming").postStopFinalizeBudget
        if budget > 0 { return budget }
        return ModelCatalog.liveCapabilities(
            for: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
        ).postStopFinalizeBudget
    }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        begin(onTranscript: onTranscript, onEvent: nil, onError: onError)
    }

    /// Canonical event surface for the Apple controllers, which keep their own
    /// per-item bookkeeping. Events are delivered throughout finalisation.
    public func start(onEvent: @escaping (Event) -> Void, onError: @escaping (Error) -> Void) {
        begin(onTranscript: nil, onEvent: onEvent, onError: onError)
    }

    /// Graceful finalisation with callbacks: commits admitted audio and closes
    /// once the committed item completes or the finalise budget elapses.
    public func stop() { synchronized { beginFinish(run, deliverCallbacks: true) } }

    /// Immediate abort. Text received so far stays available to `finishAndWait`.
    public func cancel() { synchronized { close(run) } }

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
                    active.finishWaiters.append(continuation)
                    beginFinish(active, deliverCallbacks: false)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    // MARK: - Canonical readiness and commit surface

    public var isReady: Bool { synchronized { isCurrent(run) && run.ready } }

    /// PCM admitted but not yet handed to the transport.
    public var queuedAudioByteCount: Int { synchronized { run.queuedAudioBytes } }

    /// Queues `input_audio_buffer.commit` behind the admitted audio. Nothing is
    /// sent when no audio followed the previous commit, which avoids the
    /// server's empty-buffer error; a tail shorter than 100 ms is padded first.
    public func commitInputBuffer() {
        synchronized {
            let active = run
            guard isCurrent(active), active.phase == .connecting || active.phase == .active,
                  enqueueCommit(active) else { return }
            pump(active)
        }
    }

    /// Resolves `true` once `session.updated` acknowledged the configuration and
    /// the queued prefix started moving, `false` on timeout or closure.
    public func awaitSessionReady(timeout: TimeInterval) async -> Bool {
        let active = synchronized { run }
        return await withCheckedContinuation { continuation in
            synchronized {
                guard isCurrent(active), active.phase != .idle else { continuation.resume(returning: false); return }
                if active.ready { continuation.resume(returning: true); return }
                let id = active.addReadyWaiter(continuation)
                after(timeout, active) { _, active in active.resolveReadyWaiter(id, value: false) }
            }
        }
    }

    /// Resolves once every queued frame and control message has completed
    /// sending, or immediately when nothing can move because the session is not
    /// ready, or at the timeout.
    public func awaitPendingSends(timeout: TimeInterval) async {
        let active = synchronized { run }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            synchronized {
                guard isCurrent(active), !active.isDrained else { continuation.resume(); return }
                let id = active.addDrainWaiter(continuation)
                after(timeout, active) { _, active in active.resolveDrainWaiter(id) }
            }
        }
    }

    // MARK: - Run lifecycle

    private func begin(
        onTranscript: ((String, Bool) -> Void)?, onEvent: ((Event) -> Void)?, onError: @escaping (Error) -> Void
    ) {
        synchronized {
            close(run)
            let active = OpenAIRealtimeLiveRun()
            run = active
            active.onTranscript = onTranscript
            active.onEvent = onEvent
            active.onError = onError
            guard !apiKey.isEmpty else { fail(OpenAIRealtimeStreamingError.missingAPIKey, active); return }
            guard sampleRate == OpenAIRealtimeProtocol.sampleRate else {
                fail(OpenAIRealtimeStreamingError.invalidSampleRate(sampleRate), active)
                return
            }
            guard let update = OpenAIRealtimeProtocol.sessionUpdateJSON(
                model: model, language: language, prompt: prompt, sampleRate: sampleRate,
                eventID: active.sessionUpdateEventID
            ) else { fail(OpenAIRealtimeStreamingError.encodingFailed, active); return }
            guard let request = OpenAIRealtimeProtocol.webSocketRequest(apiKey: apiKey) else {
                fail(OpenAIRealtimeStreamingError.invalidURL, active)
                return
            }
            active.outgoing = [.sessionUpdate(update)]
            active.phase = .connecting
            connect(active, request: request)
        }
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "OpenAI") }

    func fail(_ error: Error, _ active: OpenAIRealtimeLiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.finishWaiters
        active.finishWaiters.removeAll()
        let transcript = active.transcript
        close(active)
        log("Realtime session failed")
        // Publish the failure before finish returns. The run is already
        // detached, so the callback may start a replacement session safely.
        callback?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func close(_ active: OpenAIRealtimeLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.queuedAudioBytes = 0
        active.queuedAudioFrames = 0
        active.budget.reset()
        active.sending = false
        let waiters = active.finishWaiters
        active.finishWaiters.removeAll()
        connection?.cancel()
        let transcript = active.transcript
        waiters.forEach { $0.resume(returning: transcript) }
        active.resolveAllReadyWaiters(value: false)
        active.resolveAllDrainWaiters()
        active.onTranscript = nil
        active.onEvent = nil
        active.onError = nil
    }

    func isCurrent(_ active: OpenAIRealtimeLiveRun) -> Bool { active === run && active.phase != .closed }

    func after(_ seconds: TimeInterval, _ active: OpenAIRealtimeLiveRun,
               action: @escaping @Sendable (OpenAIRealtimeLiveClient, OpenAIRealtimeLiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "OpenAIRealtimeLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
