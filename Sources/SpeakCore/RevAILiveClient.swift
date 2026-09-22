import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared client for Rev AI's streaming speech-to-text WebSocket, used by
/// macOS, iOS and Windows.
///
/// Binary PCM frames go up; `connected`, `partial` and `final` JSON text frames
/// come back. `EOS` — a literal, case-sensitive text frame — commits the tail,
/// after which Rev AI sends its last hypothesis and closes normally. Rev AI
/// rejects audio before its `connected` frame, so audio captured earlier waits
/// in the run's bounded queue and leaves, in capture order, once both the real
/// handshake and `connected` have arrived (issue #641).
///
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows). Admission is synchronous and bounded by frames and by bytes;
/// one frame is in flight at a time and each completion releases the next.
/// Transport calls, scheduling, host callbacks and waiter resumptions run
/// outside the state lock, so any of them may re-enter the client. Only a
/// close frame reporting 1000 after `EOS` completes a stream: the transport
/// must surface the peer's close code through
/// `StreamingWebSocketCloseReporting`, and a failure without one is an
/// incomplete session, never a success.
///
/// Contract: https://docs.rev.ai/api/streaming/requests and
/// https://docs.rev.ai/api/streaming/responses (read 2026-09-22).
public final class RevAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Rev AI documents that a `final` hypothesis covers a section of audio
    /// whose output "will no longer change", and the next `partial` starts a
    /// fresh segment — so each final is standalone.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EOS` makes Rev AI transcribe audio it has received but not yet
    /// finalised, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    /// The whole finish deadline, so platform stop watchdogs wait for it.
    public var finalisationBudget: TimeInterval? { RevAIStreaming.finishBudget }

    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The literal end-of-stream token. Rev AI closes the socket with
    /// `1007 Invalid Payload` for any other text frame — including `eos` and
    /// `Eos` — and a real WebSocket close frame loses the final hypothesis.
    static let endOfStreamToken = "EOS"
    /// The handshake and `connected` must both arrive within this bound.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport
    /// stalled. Each send arms one inert-once-settled timer, so at most one
    /// per frame sent in the last few seconds is pending.
    static let sendDeadline: TimeInterval = 5
    /// PCM frames queued, held or in flight, pre-start audio included.
    static let maximumBufferedFrames = 256

    private let accessToken: String
    private let language: String?
    /// The rate the socket declares and the rate the caller's PCM must have.
    let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    /// Five seconds of PCM16 mono at `sampleRate`: the byte bound on audio
    /// queued, held or in flight.
    let maximumBufferedBytes: Int
    let lock = NSLock()
    /// Guarded by `lock`. Starts as the idle pre-start run.
    var run = RevAILiveRun(usesTransport: false)

    /// Existing Apple entry point. It adapts the caller's session, which the
    /// client uses but does not own or invalidate.
    public convenience init(
        accessToken: String,
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            accessToken: accessToken, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    /// `language` is the Speak selection as stored (`en_GB`, `Automatic`,
    /// nil); `RevAIStreaming.languageCode` resolves it, including the system
    /// locale for Automatic, when the request is built.
    public init(
        accessToken: String,
        language: String? = nil,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        // An undocumented rate fails at start; clamping keeps the pre-start
        // bound finite for it without trusting caller input in arithmetic.
        let rate = min(max(sampleRate, 1), RevAIStreaming.supportedSampleRates.upperBound)
        self.maximumBufferedBytes = Int(Double(rate * 2) * StreamingAudioPreroll.defaultBudgetSeconds)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let request = Self.webSocketRequest(accessToken: accessToken, sampleRate: sampleRate, language: language)
        let armed: RevAILiveRun? = withState { effects in
            let active = arm(onTranscript: onTranscript, onError: onError, usesTransport: true, &effects)
            // Audio refused before this start has already failed the run.
            guard isCurrent(active) else { return nil }
            guard !accessToken.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "Rev.ai"), active, &effects)
                return nil
            }
            // Rev AI answers an undocumented rate with 4002; refuse it here
            // instead of opening a stream to be rejected.
            guard RevAIStreaming.supportedSampleRates.contains(sampleRate) else {
                fail(RevAIStreamingError.badRequest, active, &effects)
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
    /// frames and `maximumBufferedBytes` of PCM may be held, queued or in
    /// flight. Exceeding either is reported as a terminal failure rather than
    /// evicting the user's words: before `connected` it means the session is
    /// not coming, after it that the transport stopped completing sends. Audio
    /// offered before `start()` is held under the same bounds and carried into
    /// that session. Audio offered once a finish has begun belongs to no
    /// session and is not accepted.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        withState { effects in
            let active = run
            switch active.phase {
            case .idle: holdBeforeStart(audioData, in: active)
            case .connecting, .streaming: admit(audioData, into: active, &effects)
            case .finishing, .closed: break
            }
        }
    }

    /// Immediate teardown; `cancel()` is the same path. Confirmed text stays
    /// available to `finishAndWait()`, and every waiting finish resumes.
    public func stop() { withState { effects in close(run, &effects) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, sends `EOS` and waits for the trailing
    /// hypothesis and the server's normal close, all inside the one
    /// `RevAIStreaming.finishBudget` deadline. Returns the whole confirmed
    /// transcript; finals that arrive during the finish are folded into it
    /// rather than also delivered through `onTranscript`. A finish that does
    /// not reach that close publishes its error before returning the confirmed
    /// text, including to a finish that joins while that error is still being
    /// delivered. Concurrent finishes share one outcome.
    public func finishAndWait() async -> String? {
        let active = lock.withLock { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                withState { effects in
                    guard isCurrent(active), !Task.isCancelled else {
                        if isCurrent(active) { close(active, &effects) }
                        active.answerRetired(continuation, &effects)
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

    /// Whether the handshake and `connected` have arrived and audio may leave.
    var isSessionReady: Bool { lock.withLock { isCurrent(run) && run.isReady } }

    /// Audio admitted to the current run and not yet handed to the transport.
    var preroll: RevAIHeldAudio { lock.withLock { RevAIHeldAudio(snapshot: run.heldAudio) } }

    /// PCM frames admitted and not yet completed, held audio included.
    var bufferedAudioFrames: Int { lock.withLock { run.bufferedFrames } }

    /// Finishes waiting on the current run.
    var finishWaiterCount: Int { lock.withLock { run.waiters.count } }

    /// Arms the callbacks and a fresh socket-free run. `start` is this plus a
    /// transport; tests pair it with `ingest`.
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        withState { effects in _ = arm(onTranscript: onTranscript, onError: onError, usesTransport: false, &effects) }
    }

    /// Feeds one raw server frame through the receive path. The socket loop is
    /// the only production caller; tests drive the client with it.
    func ingest(_ text: String) { withState { effects in handle(.text(text), run, &effects) } }

    /// The bounded wait for the current run to end, resolved by its close or
    /// failure or by the budget. `whenArmed` runs once the waiter is
    /// installed, so frames it delivers cannot race their own completion.
    func awaitFinalTranscript(
        budget: TimeInterval = RevAIStreaming.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        let active = lock.withLock { run }
        return await withCheckedContinuation { continuation in
            let armed: Bool = withState { effects in
                guard isCurrent(active) else {
                    active.answerRetired(continuation, &effects)
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

/// The audio a run holds for the transport, in the pre-roll shape existing
/// callers read. Nothing is ever evicted: a bound that would be exceeded fails
/// the run instead, so `droppedChunkCount` stays zero.
struct RevAIHeldAudio: Equatable {
    let snapshot: StreamingAudioPreroll.Snapshot

    var isEmpty: Bool { snapshot.byteCount == 0 }
}

// MARK: - Run lifecycle

/// Every function taking `inout RevAILiveEffects` runs with `lock` held and
/// defers anything that could re-enter the client.
extension RevAILiveClient {
    /// Runs `body` under the state lock, then performs the effects it queued.
    @discardableResult
    func withState<Value>(_ body: (inout RevAILiveEffects) -> Value) -> Value {
        var effects = RevAILiveEffects()
        lock.lock()
        let value = body(&effects)
        lock.unlock()
        effects.perform()
        return value
    }

    /// Retires the current run and installs a fresh one with its callbacks.
    /// Audio the idle run held before the first start is carried in; a refusal
    /// recorded then fails the new run at once, through its `onError`.
    func arm(
        onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void,
        usesTransport: Bool, _ effects: inout RevAILiveEffects
    ) -> RevAILiveRun {
        let previous = run
        let active = RevAILiveRun(usesTransport: usesTransport)
        active.onTranscript = onTranscript
        active.onError = onError
        active.phase = .connecting
        let refusal = previous.phase == .idle ? previous.deferredFailure : nil
        if previous.phase == .idle, refusal == nil { active.adoptHeldAudio(from: previous) }
        close(previous, &effects)
        run = active
        if let refusal { fail(refusal, active, &effects) }
        return active
    }

    /// There is no callback before `start()`, so a chunk that cannot be held
    /// is recorded for the next start to report and what was held is released
    /// with it: a partial or misaligned opening is never sent, and nothing is
    /// evicted silently.
    func holdBeforeStart(_ pcm: Data, in idle: RevAILiveRun) {
        guard idle.deferredFailure == nil else { return }
        let refusal: Error
        if !pcm.count.isMultiple(of: 2) {
            refusal = RevAILiveError.invalidPCM
        } else if idle.admit(pcm, frameLimit: Self.maximumBufferedFrames, byteLimit: maximumBufferedBytes) {
            return
        } else {
            refusal = RevAILiveError.overflowBeforeStart
        }
        idle.deferredFailure = refusal
        idle.discardOutbound()
        log("Audio offered before start was refused")
    }

    func admit(_ pcm: Data, into active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard pcm.count.isMultiple(of: 2) else {
            fail(RevAILiveError.invalidPCM, active, &effects)
            return
        }
        guard active.admit(pcm, frameLimit: Self.maximumBufferedFrames, byteLimit: maximumBufferedBytes) else {
            fail(active.isReady ? stalledError : RevAILiveError.sessionNotReady, active, &effects)
            return
        }
        requestPump(active, &effects)
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Rev.ai") }

    /// Retires the run, then publishes `error` before any finish of it
    /// returns. The run is detached first, so the callback may start a
    /// replacement. Its waiters, and any finish that joins while the callback
    /// runs, stay on the failed run and resume with its confirmed text only
    /// once the callback has returned; nothing is held under the lock meanwhile.
    func fail(_ error: Error, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        active.retire(&effects)
        active.deliveringFailure = true
        log("Session failed")
        effects.append { callback?(error) }
        effects.append { self.completeFailureDelivery(active) }
    }

    /// Ends a failed run's delivery and resumes every finish that waited on it.
    func completeFailureDelivery(_ active: RevAILiveRun) {
        withState { effects in
            active.deliveringFailure = false
            active.releaseWaiters(&effects)
        }
    }

    func close(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.retire(&effects) else { return }
        active.releaseWaiters(&effects)
    }

    func isCurrent(_ active: RevAILiveRun) -> Bool { active === run && active.phase != .closed }

    typealias RunAction = @Sendable (RevAILiveClient, RevAILiveRun, inout RevAILiveEffects) -> Void

    /// Schedules `action` for `active`; it runs under the lock only if that
    /// run is still current. Call without the lock held.
    func after(_ seconds: TimeInterval, _ active: RevAILiveRun, action: @escaping RunAction) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { action(self, active, &effects) } }
        }
    }

    /// Lifecycle events only: never the URL, the token, a frame or text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "RevAILiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
