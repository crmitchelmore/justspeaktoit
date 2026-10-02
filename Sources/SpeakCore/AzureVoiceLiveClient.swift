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
/// sent. One socket per run connects to the user's resource origin with the
/// key in the `api-key` header. The configuration leaves after the transport's
/// real handshake; PCM16 frames are admitted synchronously into a queue bounded
/// by bytes and by frames and sent one at a time once Azure's `session.updated`
/// has acknowledged that configuration. A finish sends every admitted frame,
/// then the commit, then the barrier described in `AzureVoiceLiveProtocol`, and
/// returns once the commit and the barrier are acknowledged and every announced
/// item has settled, all inside the route's catalogue finish budget.
///
/// Any failure is published through `onError` before a finish returns. Text a
/// finish withheld from `onTranscript` is delivered just before that error, so
/// a host keeps everything Azure sent without mistaking it for a completed
/// transcript. Only an empty-buffer answer to this client's own final commit
/// is benign; every other server error, including one that names the commit or
/// the barrier, ends the run as a failure.
///
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows); framing, admission and lifecycle stay here.
public final class AzureVoiceLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Every final restates the confirmed session transcript in item order, so
    /// finals replace rather than append.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    /// The bound on a finish: drain, commit, barrier and every pending final.
    public var finalisationBudget: TimeInterval? { finishBudget }

    /// The handshake and the configuration acknowledgement must land within this bound.
    static let readyDeadline: TimeInterval = 10
    /// How long a finish waits for a session that is still being configured.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Queued plus in-flight PCM is bounded by frames as well as by five seconds of bytes.
    static let maximumQueuedFrames = 256

    let credentials: String
    let endpoint: String
    let model: String
    let language: String?
    let sampleRate: Int
    let finishBudget: TimeInterval
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    /// Audio offered before `start()`, replayed into that session in capture order.
    let preroll: StreamingAudioPreroll
    /// Mirrors whether the current session's configuration was acknowledged.
    let readiness = StreamingSessionReadiness()
    private let queue = DispatchQueue(label: "AzureVoiceLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    var run: AzureVoiceLiveRun

    public convenience init(
        credentials: String,
        endpoint: String,
        model: String,
        language: String?,
        sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.init(
            credentials: credentials, endpoint: endpoint, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
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
        queue.setSpecific(key: queueKey, value: true)
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

    /// Five seconds of this session's PCM, the shared streaming hold budget.
    var maximumQueuedBytes: Int {
        sampleRate * AzureVoiceLiveProtocol.bytesPerSample * Int(StreamingAudioPreroll.defaultBudgetSeconds)
    }

    // MARK: - StreamingTranscriptionClient

    /// Replaces any current session. An invalid key, region, endpoint, rate or
    /// model is reported through `onError` before any connection is created.
    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            let held = preroll.drain()
            let active = arm(onTranscript: onTranscript, onError: onError, phase: .connecting)
            let request: URLRequest
            let update: String
            do {
                request = try Self.connectionRequest(credentials: credentials, endpoint: endpoint)
                guard AzureVoiceLiveProtocol.supportedSampleRates.contains(sampleRate) else {
                    throw AzureVoiceLiveError.unsupportedSampleRate(sampleRate)
                }
                update = try AzureVoiceLiveProtocol.sessionUpdateJSON(
                    model: model, language: language, sampleRate: sampleRate, eventID: active.sessionEventID
                )
            } catch {
                fail(error, active)
                return
            }
            active.outgoing = [.sessionUpdate(update)]
            for audio in held where isCurrent(active) { admit(audio, active) }
            guard isCurrent(active) else { return }
            connect(active, request: request)
        }
    }

    /// Synchronous, bounded admission; see `admit(_:_:)`. Audio offered before
    /// `start()` is held and replayed; audio after a finish began is not taken.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            switch active.phase {
            case .idle: preroll.append(audioData)
            case .connecting, .active: admit(audioData, active)
            case .finishing, .closed: break
            }
        }
    }

    /// Commits admitted audio and returns the confirmed whole-session transcript
    /// once everything announced has settled. A failure, the finish budget,
    /// cancellation or replacement ends it sooner; a failure is always
    /// delivered through `onError` first. Transcripts are not also delivered
    /// through `onTranscript` while finishing, unless the finish fails.
    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active) else {
                        continuation.resume(returning: active.transcript.confirmedOrNil)
                        return
                    }
                    active.waiters.append(continuation)
                    if Task.isCancelled {
                        close(active)
                    } else if active.connection == nil {
                        complete(active)
                    } else {
                        beginFinish(active)
                    }
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    /// Immediate abort; the same as `cancel()`. Confirmed text stays available
    /// to finishes, which resume with it.
    public func stop() { cancel() }

    public func cancel() { synchronized { close(run) } }

    // MARK: - Contract-test seams

    /// Whether the current session's configuration has been acknowledged.
    var isSessionReady: Bool { synchronized { isCurrent(run) && run.ready } }

    /// Finish callers waiting on the current run.
    var pendingFinishCount: Int { synchronized { run.waiters.count } }

    /// Arms the callbacks without opening a socket, as if the configuration had
    /// already left. `start` is this plus a connection; tests pair it with `ingest`.
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            preroll.reset()
            arm(onTranscript: onTranscript, onError: onError, phase: .connecting).sessionUpdateSent = true
        }
    }

    /// Feeds one raw server frame through the receive path; the socket is the
    /// only production caller.
    func ingest(_ json: String) { synchronized { handle(Data(json.utf8), run) } }

    // MARK: - Run lifecycle

    /// Replaces the current run with a fresh one whose callbacks are armed.
    @discardableResult
    private func arm(
        onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void,
        phase: AzureVoiceLiveRun.Phase
    ) -> AzureVoiceLiveRun {
        close(run)
        let active = AzureVoiceLiveRun(phase: phase)
        run = active
        active.onTranscript = onTranscript
        active.onError = onError
        readiness.reset()
        return active
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Azure Speech") }

    /// Ends the run, then publishes the failure once: text a finish withheld
    /// reaches the host first, then the error, then every finish caller resumes
    /// with the confirmed transcript. The run is already detached, so a
    /// callback may start a replacement session safely.
    func fail(_ error: Error, _ active: AzureVoiceLiveRun) {
        guard isCurrent(active) else { return }
        let onTranscript = active.onTranscript
        let onError = active.onError
        let withheld = active.withheldDeliveries
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript.confirmedOrNil
        close(active)
        log("Session failed")
        if let onTranscript { withheld.forEach { onTranscript($0.text, $0.isFinal) } }
        onError?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    /// Ends a settled finish. Silence returns nothing, but a recording in which
    /// every attempted turn failed is reported before the finish returns.
    func complete(_ active: AzureVoiceLiveRun) {
        guard isCurrent(active) else { return }
        if active.transcript.confirmedOrNil == nil, active.transcript.hasFailedItem {
            fail(AzureSpeechError.transcriptionFailed, active)
        } else {
            close(active)
        }
    }

    /// Ends a run without an error. Its socket is cancelled, queued audio is
    /// released, callbacks are dropped and waiting finishes resume with the
    /// confirmed transcript.
    func close(_ active: AzureVoiceLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.queuedAudioBytes = 0
        active.queuedAudioFrames = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        active.onTranscript = nil
        active.onError = nil
        if active === run {
            preroll.reset()
            readiness.reset()
        }
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript.confirmedOrNil
        connection?.cancel()
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func isCurrent(_ active: AzureVoiceLiveRun) -> Bool { active === run && active.phase != .closed }

    /// Schedules `action` for this run. It runs on the state queue, and only
    /// while the run is still current.
    func after(
        _ seconds: TimeInterval, _ active: AzureVoiceLiveRun,
        action: @escaping @Sendable (AzureVoiceLiveClient, AzureVoiceLiveRun) -> Void
    ) {
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
        SpeakLogger.logger(category: "AzureVoiceLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
