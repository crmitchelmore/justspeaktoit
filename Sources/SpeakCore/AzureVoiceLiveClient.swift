import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared Azure Voice Live input-transcription client used by macOS, iOS and
/// Windows, for both canonical routes (`azure-speech` and `mai-transcribe`).
///
/// Voice Live is used only for input transcription: the session is text-only,
/// turn detection never creates a response, and `response.create` is never
/// sent, so no assistant output is generated or billed. One socket per run
/// connects to the user's resource origin with the key in the `api-key` header.
/// The configuration leaves after the real handshake; 24 kHz PCM16 frames are
/// admitted synchronously into a queue bounded by bytes and by frames, and sent
/// one at a time once `session.updated` has acknowledged it. A finish drains
/// that queue, commits, sends the barrier described in `AzureVoiceLiveProtocol`
/// and waits for every announced item inside one budget.
///
/// State is confined to one lock, which is never held across a transport call
/// or a host callback. Callbacks and finish results are delivered in order by
/// one thread at a time, so a failure is always published before any finish,
/// including one that starts while the failure is being delivered, returns.
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows); framing, admission and lifecycle stay here.
///
/// Contract: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-how-to
public final class AzureVoiceLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Every final restates the confirmed session transcript in item order, so
    /// finals replace rather than append.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    /// The one budget that bounds a finish: readiness, drain, commit, barrier
    /// acknowledgement and every pending final. From the canonical catalogue.
    public var finalisationBudget: TimeInterval? { finishBudget }

    /// The handshake and the configuration acknowledgement must land within this bound.
    static let readyDeadline: TimeInterval = 10
    /// A send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Queued plus in-flight PCM is bounded by frames as well as by bytes.
    static let maximumQueuedFrames = 256
    /// Five seconds of 24 kHz PCM16, the shared streaming hold budget.
    static let maximumQueuedBytes = AzureVoiceLiveProtocol.sampleRate * AzureVoiceLiveProtocol.bytesPerSample
        * Int(StreamingAudioPreroll.defaultBudgetSeconds)

    let credentials: String
    let endpoint: String
    let model: String
    let language: String?
    let sampleRate: Int
    let finishBudget: TimeInterval
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    /// Audio offered before the first `start()`, replayed into that session in
    /// capture order. Admission keeps it within a run's bounds, so the buffer
    /// never evicts anything itself.
    let preroll: StreamingAudioPreroll
    /// Mirrors whether the current session's configuration was acknowledged.
    let readiness = StreamingSessionReadiness()

    let lock = NSLock()
    var run: AzureVoiceLiveRun
    /// Host callbacks and finish results, delivered in order outside the lock.
    var deliveries: [AzureVoiceLiveDelivery] = []
    var delivering = false
    /// Why pre-start audio could not be held; reported when the session starts.
    var heldFailure: AzureVoiceLiveError?

    public init(
        credentials: String,
        endpoint: String,
        model: String,
        language: String?,
        sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.finishBudget = Self.finishBudget(forModel: model)
        self.makeConnection = { URLSessionStreamingConnection(session: session, request: $0) }
        self.schedule = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.run = AzureVoiceLiveRun(phase: .idle)
    }

    /// Transport injection for hosts with their own WebSocket adapter.
    public init(
        credentials: String,
        endpoint: String,
        model: String,
        language: String?,
        sampleRate: Int = 24_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.finishBudget = Self.finishBudget(forModel: model)
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.run = AzureVoiceLiveRun(phase: .idle)
    }

    deinit { run.connection?.cancel() }

    /// The catalogue's post-stop budget for the route that sends this model.
    static func finishBudget(forModel model: String) -> TimeInterval {
        let routeBudget = AzureVoiceLiveProtocol.catalogID(forModel: model)
            .map { ModelCatalog.liveCapabilities(for: $0).postStopFinalizeBudget } ?? 0
        guard routeBudget > 0 else {
            return ModelCatalog.liveCapabilities(for: AzureTranscriptionModels.speechLive).postStopFinalizeBudget
        }
        return routeBudget
    }

    // MARK: - StreamingTranscriptionClient

    /// Replaces any current session. An invalid key, endpoint, rate or model is
    /// reported through `onError` before any connection is created.
    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let plan: AzureVoiceLiveConnectionPlan? = transact { effects in
            let held = takeHeldAudio()
            let active = arm(onTranscript: onTranscript, onError: onError, phase: .connecting, &effects)
            return prepare(active, held: held, &effects)
        }
        if let plan { connect(plan.run, request: plan.request) }
    }

    /// Synchronous, bounded admission; see `admit(_:_:)`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        transact { effects in admit(audioData, &effects) }
    }

    /// Commits admitted audio and returns the confirmed whole-session transcript
    /// once every announced item has settled, or when the finish budget, a
    /// failure, cancellation or replacement ends the run. A failure is always
    /// delivered through `onError` first. Concurrent and repeated calls for one
    /// run share its single result; transcripts are not also delivered through
    /// `onTranscript` while finishing.
    public func finishAndWait() async -> String? {
        let active = lock.withLock { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                transact { effects in join(active, continuation, &effects) }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.transact { effects in
                if self.isCurrent(active) { self.close(active, &effects) }
            }
        }
    }

    /// Immediate abort; the same as `cancel()`. Confirmed text stays available
    /// to a finish, and waiting finishes resume with it.
    public func stop() { cancel() }

    public func cancel() {
        transact { effects in
            if run.phase == .idle { discardHeldAudio() }
            close(run, &effects)
        }
    }

    // MARK: - Contract-test seams

    /// Whether the current session's configuration has been acknowledged.
    var isSessionReady: Bool { lock.withLock { isCurrent(run) && run.ready } }

    /// Finish callers waiting on the current run.
    var pendingFinishCount: Int { lock.withLock { run.waiters.count } }

    /// Callbacks and finish results queued behind the one being delivered.
    var queuedDeliveryCount: Int { lock.withLock { deliveries.count } }

    /// Arms the callbacks without opening a socket: an explicitly detached run
    /// for contract tests, paired with `ingest`. `start` is this plus a connection.
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        transact { effects in
            discardHeldAudio()
            _ = arm(onTranscript: onTranscript, onError: onError, phase: .detached, &effects)
        }
    }

    /// Feeds one raw server frame through the receive path; the socket is the
    /// only production caller. A never-started client becomes a detached run.
    /// A connecting run is treated exactly as its socket would treat the frame.
    func ingest(_ json: String) {
        transact { effects in
            if run.phase == .idle {
                discardHeldAudio()
                run.phase = .detached
            }
            guard isCurrent(run) else { return }
            handleFrame(Data(json.utf8), run, &effects)
        }
    }
}

/// Work computed under the state lock and performed after it is released:
/// transport calls and scheduling never run while the lock is held.
struct AzureVoiceLiveEffects {
    private var actions: [() -> Void] = []

    mutating func append(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }
}

/// A host callback or finish result, queued under the lock and delivered in
/// order by one thread at a time with the lock released.
enum AzureVoiceLiveDelivery {
    case transcript((String, Bool) -> Void, text: String, isFinal: Bool)
    case failure((Error) -> Void, Error)
    case finish(CheckedContinuation<String?, Never>, String?)

    func perform() {
        switch self {
        case .transcript(let callback, let text, let isFinal): callback(text, isFinal)
        case .failure(let callback, let error): callback(error)
        case .finish(let continuation, let transcript): continuation.resume(returning: transcript)
        }
    }
}

struct AzureVoiceLiveConnectionPlan {
    let run: AzureVoiceLiveRun
    let request: URLRequest
}

extension AzureVoiceLiveClient {
    /// Runs `body` under the state lock, then performs the transport work it
    /// queued and delivers pending callbacks, both with the lock released.
    /// Only entry points call this; `body` must not re-enter it.
    @discardableResult
    func transact<Value>(_ body: (inout AzureVoiceLiveEffects) -> Value) -> Value {
        var effects = AzureVoiceLiveEffects()
        let value = lock.withLock { body(&effects) }
        effects.perform()
        deliverPending()
        return value
    }

    /// Delivers queued callbacks in order. A callback that re-enters the client
    /// only queues more work, which this loop then delivers after it returns.
    func deliverPending() {
        let claimed = lock.withLock { () -> Bool in
            guard !delivering else { return false }
            delivering = true
            return true
        }
        guard claimed else { return }
        while let next = lock.withLock({ () -> AzureVoiceLiveDelivery? in
            guard !deliveries.isEmpty else {
                delivering = false
                return nil
            }
            return deliveries.removeFirst()
        }) {
            next.perform()
        }
    }

    func isCurrent(_ active: AzureVoiceLiveRun) -> Bool { active === run && active.phase != .closed }

    /// Replaces the current run with a fresh one whose callbacks are armed.
    func arm(
        onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void,
        phase: AzureVoiceLiveRun.Phase, _ effects: inout AzureVoiceLiveEffects
    ) -> AzureVoiceLiveRun {
        close(run, &effects)
        let active = AzureVoiceLiveRun(phase: phase)
        run = active
        active.onTranscript = onTranscript
        active.onError = onError
        readiness.reset()
        return active
    }

    /// Validates everything a connection needs, then queues the configuration
    /// and any held audio. Nothing is connected when validation fails.
    func prepare(
        _ active: AzureVoiceLiveRun, held: AzureVoiceLiveHeldAudio, _ effects: inout AzureVoiceLiveEffects
    ) -> AzureVoiceLiveConnectionPlan? {
        let request: URLRequest
        let update: String
        do {
            guard let configuration = try? AzureSpeechConfiguration(credentials: credentials) else {
                throw AzureVoiceLiveError.invalidCredentials
            }
            guard let origin = try? AzureSpeechConfiguration.resourceURL(endpoint),
                  let built = AzureVoiceLiveProtocol.webSocketRequest(origin: origin, apiKey: configuration.apiKey)
            else { throw AzureVoiceLiveError.invalidResourceEndpoint }
            guard sampleRate == AzureVoiceLiveProtocol.sampleRate else {
                throw AzureVoiceLiveError.unsupportedSampleRate(sampleRate)
            }
            update = try AzureVoiceLiveProtocol.sessionUpdateJSON(
                model: model, language: language, eventID: active.sessionEventID
            )
            if let failure = held.failure { throw failure }
            request = built
        } catch {
            fail(error, active, &effects)
            return nil
        }
        active.outgoing = [.sessionUpdate(update)]
        held.audio.forEach { enqueueAudio($0, active) }
        return AzureVoiceLiveConnectionPlan(run: active, request: request)
    }

    /// Ends a run. The connection is cancelled after the lock is released,
    /// and waiting finishes resume, after any earlier delivery, with the
    /// confirmed transcript.
    func close(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        if let connection = active.connection { effects.append { connection.cancel() } }
        active.connection = nil
        active.outgoing.removeAll()
        active.queuedAudioBytes = 0
        active.queuedAudioFrames = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        let transcript = active.transcript.confirmedOrNil
        active.waiters.forEach { deliveries.append(.finish($0, transcript)) }
        active.waiters.removeAll()
        active.onTranscript = nil
        active.onError = nil
        if active === run { readiness.reset() }
    }

    /// Closes the run, then publishes the error once. Deliveries are ordered,
    /// so every finish waiter, including one that joins while the error is
    /// being delivered, resumes only after the callback returns. The run is
    /// already closed, so the callback may start a replacement session.
    func fail(_ error: Error, _ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        close(active, &effects)
        log("Session failed")
        if let callback { deliveries.append(.failure(callback, error)) }
        let transcript = active.transcript.confirmedOrNil
        waiters.forEach { deliveries.append(.finish($0, transcript)) }
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Azure Speech") }

    /// Schedules `action` for this run after the lock is released. It runs
    /// under the lock, and only while the run is still current.
    func after(
        _ seconds: TimeInterval, _ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects,
        action: @escaping @Sendable (AzureVoiceLiveClient, AzureVoiceLiveRun, inout AzureVoiceLiveEffects) -> Void
    ) {
        let schedule = self.schedule
        effects.append {
            schedule(seconds) { [weak self, weak active] in
                guard let self, let active else { return }
                self.transact { effects in
                    guard self.isCurrent(active) else { return }
                    action(self, active, &effects)
                }
            }
        }
    }

    /// Lifecycle events only: never a key, a frame or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "AzureVoiceLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
