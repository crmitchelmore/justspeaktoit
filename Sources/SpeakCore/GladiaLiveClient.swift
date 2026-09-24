import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Gladia Live Client (portable, injected transports)

/// Portable Gladia Solaria live client.
///
/// iOS builds it through `LiveTranscriptionClientFactory` and Windows through
/// the desktop live projection. It compiles for every platform, but the macOS
/// app's production Gladia route still runs its own controller and
/// transcriber in `SpeakApp`; Mac capture has not been moved onto this client.
///
/// Gladia is two-stage: `POST /v2/live` with `x-gladia-key` creates a session
/// and returns a single-use WebSocket URL carrying its own temporary token.
/// PCM16 mono chunks are admitted synchronously into one bounded queue from
/// `start()` onward and sent one at a time, as binary frames, once the socket
/// handshake completes. A finish drains that queue, sends `stop_recording`
/// behind the last chunk and waits for `end_session` inside one whole deadline.
/// Both transports are injected (`URLSession` through the original
/// initializer, as on iOS; the desktop projection's HTTPS request plus the
/// host's native socket on Windows) while framing, admission, ordering and run
/// identity stay here, so the platforms that use it cannot drift. See
/// `GladiaLive` for the contract.
///
/// State changes happen under one lock. Transport calls, deadlines, callbacks
/// and finish waiters run after it is released, in the order the state changed;
/// each transport effect re-checks its run first. A failure is reported after
/// transcripts already being delivered, and before any finish returns.
public final class GladiaLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Each final `transcript` carries one utterance, identified by `data.id`.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `stop_recording` makes Gladia process audio it has not transcribed yet,
    /// so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    /// The whole bound `finishAndWait()` applies, for host stop watchdogs.
    public var finalisationBudget: TimeInterval? { GladiaLive.finishBudget }

    public typealias SessionInitiator = @Sendable (
        URLRequest, @escaping @Sendable (Result<(statusCode: Int, body: Data), Error>) -> Void
    ) -> any GladiaLiveSessionRequest
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The session request and the socket handshake must complete in this bound.
    static let readyDeadline: TimeInterval = 10
    /// Admitted chunks are bounded by count as well as by the byte budget.
    static let maximumQueuedChunks = 256

    let apiKey: String
    let model: String
    let language: String?
    let sampleRate: Int
    let endpoint: URL
    let initiateSession: SessionInitiator
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let lock = NSLock()
    /// The current run. Read and replaced only under `lock`.
    var run: GladiaLiveRun

    public init(
        apiKey: String,
        model: String = "solaria-1",
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = GladiaLiveProtocol.apiModelName(from: model)
        self.language = language
        self.sampleRate = sampleRate
        self.endpoint = GladiaLive.baseURL.appendingPathComponent(GladiaLiveProtocol.initPath)
        self.initiateSession = Self.sessionInitiator(session: session)
        self.makeConnection = { URLSessionStreamingConnection(session: session, request: $0) }
        self.schedule = Self.defaultScheduler
        self.run = GladiaLiveRun(sampleRate: sampleRate)
    }

    /// Injected transports: `initiateSession` performs `POST /v2/live` and
    /// `makeConnection` opens the returned socket, so each can be held or
    /// completed independently. `baseURL` defaults to Gladia's API.
    public init(
        apiKey: String,
        model: String = GladiaLive.defaultModel,
        language: String? = nil,
        sampleRate: Int = 16_000,
        baseURL: URL = GladiaLive.baseURL,
        initiateSession: @escaping SessionInitiator,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = GladiaLiveProtocol.apiModelName(from: model)
        self.language = language
        self.sampleRate = sampleRate
        self.endpoint = baseURL.appendingPathComponent(GladiaLiveProtocol.initPath)
        self.initiateSession = initiateSession
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = GladiaLiveRun(sampleRate: sampleRate)
    }

    deinit {
        let (request, connection) = lock.withLock { (run.sessionRequest, run.connection) }
        request?.cancel()
        connection?.cancel()
    }

    /// The production `POST /v2/live`: one cancellable `URLSessionDataTask`.
    public static func sessionInitiator(session: URLSession) -> SessionInitiator {
        { request, completion in
            let pending = GladiaURLSessionRequest(session: session, request: request, completion: completion)
            pending.resume()
            return pending
        }
    }

    static let defaultScheduler: Scheduler = { seconds, action in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
    }

    // MARK: - StreamingTranscriptionClient

    /// Starts a new run, aborting any previous one first. Its waiters resume
    /// with that run's confirmed text; nothing of it can reach the new run.
    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        perform { effects in
            close(run, &effects)
            let active = GladiaLiveRun(sampleRate: sampleRate)
            run = active
            active.onTranscript = onTranscript
            active.onError = onError
            begin(active, &effects)
        }
    }

    /// Immediate abort: abandons the session request or socket and wakes
    /// every finish waiter with the confirmed text. No error is reported.
    public func stop() { perform { close(run, &$0) } }

    /// Immediate abort, identical to `stop()`.
    public func cancel() { perform { close(run, &$0) } }

    /// Drains admitted PCM, sends `stop_recording` behind it and waits for
    /// `end_session`, inside `GladiaLive.finishBudget` from the moment the
    /// first finish begins. Concurrent and repeated finishes share one
    /// outcome. Returns the confirmed transcript of the whole session, or
    /// `nil` when nothing was transcribed. A failure is published through
    /// `onError` before any finish returns, including one that joins while
    /// that report is still being delivered. Cancelling the calling task
    /// aborts the run.
    public func finishAndWait() async -> String? {
        let active = lock.withLock { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                perform { effects in
                    if active.reportingFailure {
                        // Retired by a failure whose report has not returned:
                        // resumed with the others once it has.
                        active.waiters.append(continuation)
                        return
                    }
                    guard isCurrent(active), active.stage != .idle else {
                        let transcript = active.transcript
                        effects.append { continuation.resume(returning: transcript) }
                        return
                    }
                    active.waiters.append(continuation)
                    if Task.isCancelled {
                        close(active, &effects)
                    } else {
                        beginFinish(active, &effects)
                    }
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.perform { effects in if self.isCurrent(active) { self.close(active, &effects) } }
        }
    }

    // MARK: - Test and diagnostics seams

    var currentStage: GladiaLiveRun.Stage { lock.withLock { run.stage } }
    var admittedAudioBytes: Int { lock.withLock { run.admittedAudioBytes } }
    var admittedAudioChunks: Int { lock.withLock { run.admittedAudioChunks } }
    var finishWaiterCount: Int { lock.withLock { run.waiters.count } }

    // MARK: - Lifecycle core

    /// Applies a state change under the lock, then performs the effects it
    /// decided on after releasing it.
    @discardableResult
    func perform<Value>(_ change: (inout GladiaLiveEffects) -> Value) -> Value {
        var effects = GladiaLiveEffects()
        let value = lock.withLock { change(&effects) }
        effects.run()
        return value
    }
}

extension GladiaLiveClient {
    /// Caller holds the lock.
    func isCurrent(_ active: GladiaLiveRun) -> Bool { active === run && active.stage != .closed }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Gladia") }

    /// Retires the run, then reports the error, then resumes its finish waiters
    /// with the confirmed text. The run is closed before `onError` runs, so the
    /// callback may start a replacement that nothing here can touch. Until the
    /// report has returned, the run keeps every finish waiter parked, including
    /// ones that join after it closed. The report itself waits for transcript
    /// callbacks already in flight; the caller that failed the run, perhaps on
    /// the capture path, never waits for either.
    func fail(_ error: Error, _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        active.reportingFailure = true
        close(active, &effects)
        log("Gladia live session failed")
        let report: () -> Void = { [self] in
            callback?(error)
            reportDelivered(active)
        }
        if active.transcriptCallbacksInFlight == 0 {
            effects.append(report)
        } else {
            active.deferredReport = report
        }
    }

    /// `onError` returned: resume every waiter the failed run parked.
    private func reportDelivered(_ active: GladiaLiveRun) {
        perform { effects in
            active.reportingFailure = false
            let waiters = active.waiters
            active.waiters.removeAll()
            let transcript = active.transcript
            effects.append { waiters.forEach { $0.resume(returning: transcript) } }
        }
    }

    /// An `onTranscript` call returned; a failure report held behind the last
    /// one in flight is delivered now, by the thread that delivered it.
    func transcriptCallbackReturned(_ active: GladiaLiveRun) {
        perform { effects in
            active.transcriptCallbacksInFlight -= 1
            guard active.transcriptCallbacksInFlight == 0, let report = active.deferredReport else { return }
            active.deferredReport = nil
            effects.append(report)
        }
    }

    /// Ends the run: abandons its request and socket, invalidates every
    /// pending send, receive and deadline, and resumes its waiters unless a
    /// failure's report still has to reach the host first.
    func close(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard active.stage != .closed else { return }
        active.stage = .closed
        let request = active.sessionRequest
        let connection = active.connection
        active.sessionRequest = nil
        active.connection = nil
        active.outgoing.removeAll()
        active.admittedAudioBytes = 0
        active.admittedAudioChunks = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        active.sendCallActive = false
        active.earlySendOutcome = nil
        active.sendGeneration &+= 1
        active.receiveCallActive = false
        active.earlyReceive = nil
        active.receiveGeneration &+= 1
        var waiters: [CheckedContinuation<String?, Never>] = []
        if !active.reportingFailure { swap(&waiters, &active.waiters) }
        let transcript = active.transcript
        active.onTranscript = nil
        active.onError = nil
        effects.append {
            request?.cancel()
            connection?.cancel()
            waiters.forEach { $0.resume(returning: transcript) }
        }
    }

    /// Schedules `action` for the run. A deadline that fires after the run
    /// closed or was replaced does nothing.
    func arm(
        _ seconds: TimeInterval, _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects,
        action: @escaping @Sendable (GladiaLiveClient, GladiaLiveRun, inout GladiaLiveEffects) -> Void
    ) {
        let deadline: @Sendable () -> Void = { [weak self, weak active] in
            guard let self, let active else { return }
            self.perform { effects in if self.isCurrent(active) { action(self, active, &effects) } }
        }
        let schedule = schedule
        effects.append { schedule(seconds, deadline) }
    }

    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "GladiaLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
