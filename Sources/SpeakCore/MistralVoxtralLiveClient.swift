import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared client for Mistral's Voxtral Realtime transcription socket, used by
/// macOS, iOS and Windows.
///
/// Unlike every other provider here, audio is **base64 inside JSON text
/// frames** (`input_audio.append`), not binary frames. The service streams
/// append-only `transcription.text.delta` fragments and no per-utterance final;
/// the single authoritative transcript arrives as `transcription.done` after
/// `input_audio.flush` and `input_audio.end`. This client therefore folds the
/// deltas itself and reports cumulative interim text, so consumers see the same
/// shape they get from every other provider.
///
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows). `session.update` leaves only after the real handshake and
/// `session.created`, and PCM only after that update's send has completed, the
/// order Mistral's SDK uses. Audio captured earlier waits in the run's bounded
/// queue rather than being dropped (issue #641). One frame is in flight at a
/// time and each completion releases the next, so a transport that completes
/// synchronously never nests sends. Transport calls, callbacks and waiter
/// resumptions happen outside the state lock, so any of them may re-enter.
/// Frame shapes and limits live in `MistralVoxtralRealtime`.
public final class MistralVoxtralLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// `transcription.done` restates the whole session, and it is the only
    /// final this service emits.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    /// `input_audio.flush` commits audio Voxtral has received but not yet
    /// transcribed, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    /// The whole finish deadline, from the constant the catalogue declares as
    /// this model's `postStopFinalizeBudget`, so platform watchdogs agree.
    public var finalisationBudget: TimeInterval? { MistralVoxtralRealtime.finishBudget }

    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The handshake and `session.update` must complete within this bound.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Append frames queued or in flight, including audio held before readiness.
    static let maximumBufferedFrames = 256
    /// Seconds of PCM the encoded byte bound is sized for.
    static let bufferedAudioSeconds = 5

    private let apiKey: String
    private let model: String
    /// The rate `session.update` declares and the caller's PCM is encoded at.
    let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    /// Encoded bytes of queued and in-flight append frames: the base64 of
    /// `bufferedAudioSeconds` of PCM plus the wrapper and padding of every
    /// frame the count bound admits, so that much audio fits in any framing.
    let maximumBufferedBytes: Int
    let lock = NSLock()
    /// Guarded by `lock`.
    var run = MistralVoxtralLiveRun()
    /// The pre-start priming contract shared with the other clients: audio
    /// offered before `start()` is held here and carried into the run, in
    /// capture order, through the same bounded admission as live audio.
    let preroll: StreamingAudioPreroll

    /// Existing Apple entry point. It adapts the caller's session, which the
    /// client uses but does not own or invalidate.
    public convenience init(
        apiKey: String,
        model: String = MistralVoxtralRealtime.apiModelID,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String,
        model: String = MistralVoxtralRealtime.apiModelID,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.isEmpty ? MistralVoxtralRealtime.apiModelID : model
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        let pcmBytes = max(sampleRate, 1) * 2 * Self.bufferedAudioSeconds
        self.maximumBufferedBytes = 4 * ((pcmBytes + 2) / 3)
            + Self.maximumBufferedFrames * (Self.appendFrameWrapperBytes + 3)
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let request = Self.webSocketRequest(apiKey: apiKey, model: model)
        let armed: MistralVoxtralLiveRun? = withState { effects in
            let active = arm(onTranscript: onTranscript, onError: onError, &effects)
            // Carried pre-start audio can already have failed the run.
            guard isCurrent(active) else { return nil }
            guard !apiKey.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "Mistral"), active, &effects)
                return nil
            }
            guard request != nil else {
                fail(StreamingClientError.invalidURL, active, &effects)
                return nil
            }
            return active
        }
        guard let armed, let request else { return }
        connect(armed, request: request)
    }

    /// Admission is synchronous and bounded: at most `maximumBufferedFrames`
    /// append frames and `maximumBufferedBytes` of their encoding may be queued
    /// or in flight, audio held before readiness included. Exceeding either is
    /// evidence the transport stopped working or the session is not coming, and
    /// is reported as a terminal failure rather than discarding opening words.
    /// Nothing is accepted once a finish has begun.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        withState { effects in
            let active = run
            switch active.phase {
            case .idle: preroll.append(audioData)
            case .connecting, .streaming: admit(audioData, into: active, &effects)
            case .finishing, .closed: break
            }
        }
    }

    /// Immediate teardown; `cancel()` is the same path. Text received so far
    /// stays available to `finishAndWait()`, and every waiting finish resumes.
    public func stop() { withState { effects in close(run, &effects) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, then sends the flush, then the end, and
    /// waits for `transcription.done`, all inside the one `finishBudget`
    /// deadline. Returns the whole session transcript, so a done it consumes
    /// is not also delivered through `onTranscript`. A finish that does not
    /// reach `transcription.done` publishes its error before returning the text
    /// folded so far. Concurrent finishes share that one outcome.
    public func finishAndWait() async -> String? {
        let active = lock.withLock { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                withState { effects in
                    guard isCurrent(active), !Task.isCancelled else {
                        if isCurrent(active) { close(active, &effects) }
                        let transcript = active.transcript
                        effects.append { continuation.resume(returning: transcript) }
                        return
                    }
                    active.waiters.append(continuation)
                    beginFinish(active, &effects)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { self.close(active, &effects) } }
        }
    }

    // MARK: - Session seams

    /// Whether the session is configured and accepts audio.
    var isSessionReady: Bool { lock.withLock { isCurrent(run) && run.configured } }

    /// Append frames admitted and not yet completed, held audio included.
    var bufferedAudioFrames: Int { lock.withLock { run.bufferedFrames } }

    /// Finishes waiting on the current run.
    var finishWaiterCount: Int { lock.withLock { run.waiters.count } }

    /// Arms the callbacks and a fresh run without opening a socket. `start` is
    /// this plus `connect`; tests pair it with `ingest`.
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        withState { effects in _ = arm(onTranscript: onTranscript, onError: onError, &effects) }
    }

    /// Feeds one raw server frame through the receive path. The socket loop is
    /// the only production caller; tests drive the client with it.
    func ingest(_ text: String) { withState { effects in handle(.text(text), run, &effects) } }

    /// The bounded wait for `transcription.done`, resolved by that frame or by
    /// the budget. `whenArmed` runs once the waiter is installed, so a frame it
    /// delivers cannot race its own completion; tests use it to deliver frames
    /// into an armed finish without a socket.
    func awaitFinalTranscript(
        budget: TimeInterval = MistralVoxtralRealtime.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        let active = lock.withLock { run }
        return await withCheckedContinuation { continuation in
            let armed: Bool = withState { effects in
                guard isCurrent(active) else {
                    let transcript = active.transcript
                    effects.append { continuation.resume(returning: transcript) }
                    return false
                }
                active.waiters.append(continuation)
                return true
            }
            guard armed else { return }
            after(budget, active) { client, active, effects in client.close(active, &effects) }
            whenArmed()
        }
    }
}

// MARK: - Run lifecycle

/// Every function taking `inout MistralVoxtralLiveEffects` runs with `lock`
/// held and defers anything that could re-enter the client.
extension MistralVoxtralLiveClient {
    /// Runs `body` under the state lock, then performs the effects it queued.
    @discardableResult
    func withState<Value>(_ body: (inout MistralVoxtralLiveEffects) -> Value) -> Value {
        var effects = MistralVoxtralLiveEffects()
        lock.lock()
        let value = body(&effects)
        lock.unlock()
        effects.perform()
        return value
    }

    /// Retires the current run and installs a fresh one with its callbacks,
    /// carrying audio offered before the first start into it.
    func arm(
        onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void,
        _ effects: inout MistralVoxtralLiveEffects
    ) -> MistralVoxtralLiveRun {
        let carried = run.phase == .idle ? preroll.drain() : []
        close(run, &effects)
        preroll.reset()
        let active = MistralVoxtralLiveRun()
        run = active
        active.onTranscript = onTranscript
        active.onError = onError
        active.phase = .connecting
        active.outgoing.append(.sessionUpdate)
        for chunk in carried where isCurrent(active) { admit(chunk, into: active, &effects) }
        return active
    }

    func admit(_ pcm: Data, into active: MistralVoxtralLiveRun, _ effects: inout MistralVoxtralLiveEffects) {
        guard pcm.count.isMultiple(of: 2) else {
            fail(MistralRealtimeStreamingError.invalidPCM, active, &effects)
            return
        }
        guard active.admit(pcm, frameLimit: Self.maximumBufferedFrames, byteLimit: maximumBufferedBytes) else {
            fail(stalledError, active, &effects)
            return
        }
        requestPump(active, &effects)
    }

    /// Stop sequencing: stop accepting audio, drain what was admitted, flush,
    /// then end, then wait for `transcription.done`. A session that is still
    /// connecting keeps its capture and sends it once configured. One deadline
    /// bounds the whole finish; which step it catches decides the error.
    func beginFinish(_ active: MistralVoxtralLiveRun, _ effects: inout MistralVoxtralLiveEffects) {
        guard active.phase != .finishing else { return }
        // The socket-free seam, or a session that captured no audio: there is
        // nothing to flush, so the finish is the text heard so far.
        guard active.connection != nil, active.admittedAudioBytes > 0 else {
            close(active, &effects)
            return
        }
        active.phase = .finishing
        active.outgoing.append(.flush)
        active.outgoing.append(.end)
        log("Finishing")
        requestPump(active, &effects)
        effects.append { [weak self] in
            self?.after(MistralVoxtralRealtime.finishBudget, active) { client, active, effects in
                guard active.phase == .finishing else { return }
                client.fail(client.finishDeadlineError(active), active, &effects)
            }
        }
    }

    func finishDeadlineError(_ active: MistralVoxtralLiveRun) -> Error {
        if !active.configured { return MistralRealtimeStreamingError.sessionNotReady }
        if active.endHandedOff, !active.sending { return MistralRealtimeStreamingError.missingCompletion }
        return stalledError
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Mistral") }

    /// Retires the run, then publishes `error` before any waiting finish
    /// resumes. The run is detached first, so the callback may start a
    /// replacement; these waiters still resume with the failed run's text.
    func fail(_ error: Error, _ active: MistralVoxtralLiveRun, _ effects: inout MistralVoxtralLiveEffects) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        close(active, &effects)
        log("Session failed")
        effects.append { callback?(error) }
        effects.append { waiters.forEach { $0.resume(returning: transcript) } }
    }

    func close(_ active: MistralVoxtralLiveRun, _ effects: inout MistralVoxtralLiveEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.discardOutbound()
        if active === run { preroll.reset() }
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        active.onTranscript = nil
        active.onError = nil
        if let connection { effects.append { connection.cancel() } }
        if !waiters.isEmpty { effects.append { waiters.forEach { $0.resume(returning: transcript) } } }
    }

    func isCurrent(_ active: MistralVoxtralLiveRun) -> Bool { active === run && active.phase != .closed }

    typealias RunAction = @Sendable (MistralVoxtralLiveClient, MistralVoxtralLiveRun, inout MistralVoxtralLiveEffects)
        -> Void

    /// Schedules `action` for `active`, which runs under the lock only if that
    /// run is still current. Call without the lock held.
    func after(_ seconds: TimeInterval, _ active: MistralVoxtralLiveRun, action: @escaping RunAction) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { action(self, active, &effects) } }
        }
    }

    /// Lifecycle events only: never a key, a frame or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "MistralVoxtralLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
