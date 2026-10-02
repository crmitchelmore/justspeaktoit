import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Rev AI Live Client (portable, injected transport)

/// Shared client for Rev AI's streaming speech-to-text WebSocket. macOS and iOS
/// reach it through `LiveTranscriptionClientFactory`, Windows through
/// `DesktopLiveTranscription`.
///
/// Binary PCM frames go up; `connected`, `partial` and `final` JSON text frames
/// come back (see `RevAIStreaming`). Rev AI rejects audio before `connected`,
/// so PCM is admitted synchronously into one bounded queue from `start()` (or
/// earlier) and sent one frame at a time once that frame arrives, in capture
/// order (issue #641). A graceful finish drains every admitted frame, sends the
/// literal `EOS` and waits, inside one bounded budget, for the trailing final
/// and the server's normal closure. The transport is injected
/// (`URLSessionStreamingConnection` on Apple, WinHTTP on Windows); framing,
/// admission and lifecycle stay here so the platforms cannot drift.
///
/// State lives under one lock that is never held across a transport call, a
/// host callback, a scheduler call or a continuation resume.
public final class RevAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Rev AI documents that a `final` hypothesis covers a section of audio
    /// whose output "will no longer change", and the next `partial` starts a
    /// fresh segment — so each final is standalone.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EOS` makes Rev AI transcribe audio it has received but not yet
    /// finalised, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The literal end-of-stream token. Rev AI closes the socket with
    /// `1007 Invalid Payload` for any other text frame — including `eos` and
    /// `Eos` — and a real WebSocket close frame loses the final hypothesis.
    static let endOfStreamToken = "EOS"

    /// Exposes the one whole-finish deadline to host lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { RevAIStreaming.finishBudget }
    /// A finish that lands before `connected` waits at most this long for it.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// `connected` must arrive within this bound of `start()`.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// How long a send that failed without a close status waits for the
    /// receive side to report the closure that explains it (a 4003 names
    /// exhausted credit where the send only saw a broken socket).
    static let sendFailureGrace: TimeInterval = 1
    /// Seconds of PCM that may be queued or in flight, including audio held
    /// until `connected`.
    static let bufferedAudioSeconds: Double = StreamingAudioPreroll.defaultBudgetSeconds
    /// Frames that may be queued or in flight, alongside the byte bound.
    static let maximumQueuedFrames = 256

    private let accessToken: String
    private let language: String?
    private let sampleRate: Int
    private let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let lock = NSLock()
    private(set) var run: RevAILiveRun

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
        self.run = RevAILiveRun(sampleRate: sampleRate)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let opening: (RevAILiveRun, URLRequest)? = withState { effects in
            let active: RevAILiveRun
            if run.phase == .idle {
                // Audio offered before the first start is already queued, in order.
                active = run
            } else {
                retire(run, &effects)
                active = RevAILiveRun(sampleRate: sampleRate)
                run = active
            }
            active.phase = .connecting
            active.onTranscript = onTranscript
            active.onError = onError
            if let failure = active.pendingFailure {
                fail(active, failure, &effects)
                return nil
            }
            guard !accessToken.isEmpty else {
                fail(active, StreamingClientError.missingAPIKey(provider: "Rev.ai"), &effects)
                return nil
            }
            guard let url = Self.webSocketURL(
                accessToken: accessToken, sampleRate: sampleRate, language: language
            ) else {
                fail(active, StreamingClientError.invalidURL, &effects)
                return nil
            }
            after(Self.readyDeadline, active, &effects) { client, active, effects in
                if !active.ready { client.fail(active, RevAILiveError.sessionNotReady, &effects) }
            }
            return (active, URLRequest(url: url))
        }
        guard let opening else { return }
        connect(opening.0, request: opening.1)
    }

    /// Admission is synchronous and bounded: at most `bufferedAudioSeconds` of
    /// PCM and `maximumQueuedFrames` frames may be queued or in flight,
    /// including audio held until `connected`. Exceeding either is reported
    /// (as an unready session before `connected`, a stalled transport after)
    /// instead of silently trimming the recording, and a frame of partial
    /// samples is refused before it could misalign every later sample. Audio
    /// before the first `start()` is held under the same bounds and a failure
    /// there is reported by `start()`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let outbound: RevAIOutbound? = withState { effects in
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming,
                  active.pendingFailure == nil, active.sendFailure == nil else { return nil }
            let failure: Error?
            if !audioData.count.isMultiple(of: 2) {
                failure = RevAILiveError.invalidPCM
            } else if active.admittedFrames >= Self.maximumQueuedFrames
                || active.admittedBytes + audioData.count > active.maximumBytes {
                failure = active.ready ? stalledError : RevAILiveError.sessionNotReady
            } else {
                failure = nil
            }
            guard let failure else {
                active.outgoing.append(audioData)
                active.admittedBytes += audioData.count
                active.admittedAudio = true
                return claim(active, &effects)
            }
            if active.phase == .idle {
                // No callbacks exist yet. The held audio can no longer be sent
                // intact, so it is released now and `start()` reports why.
                active.pendingFailure = failure
                active.outgoing.removeAll()
                active.admittedBytes = 0
            } else {
                fail(active, failure, &effects)
            }
            return nil
        }
        if let outbound { drive(outbound) }
    }

    /// Immediate teardown; `cancel()` is the same path. A pending handshake,
    /// drain or finish is aborted at once and every waiter resumes with the
    /// text confirmed so far. Nothing is published as an error.
    public func stop() { withState { retire(run, &$0) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, sends `EOS` and waits for the trailing
    /// final and the server's normal closure, all inside
    /// `RevAIStreaming.finishBudget`. Returns the whole session transcript, or
    /// `nil` when no final had words; finals that arrive during the finish are
    /// folded into it rather than also delivered through `onTranscript`. A
    /// finish that cannot reach that documented end publishes its error before
    /// returning the confirmed text, also to callers that join while the error
    /// is being delivered. Concurrent callers share one outcome; cancelling
    /// the calling task aborts the session.
    public func finishAndWait() async -> String? {
        let active: RevAILiveRun = withState { _ in run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                withState { effects in join(active, continuation, &effects) }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { self.retire(active, &effects) } }
        }
    }

    // MARK: - Session

    private func join(
        _ active: RevAILiveRun, _ continuation: CheckedContinuation<String?, Never>,
        _ effects: inout RevAILiveEffects
    ) {
        let transcript = active.transcript
        switch active.phase {
        case .connecting, .streaming, .finishing:
            guard !Task.isCancelled else {
                retire(active, &effects)
                effects.add { continuation.resume(returning: transcript) }
                return
            }
            active.waiters.append(continuation)
            beginFinish(active, &effects)
        case .idle:
            // Never started, so nothing was sent and nothing can be finished.
            retire(active, &effects)
            effects.add { continuation.resume(returning: transcript) }
        case .closed:
            // A failure still being published keeps late callers until its
            // error is out, exactly like callers that were already waiting.
            guard !active.deliveringFailure else {
                active.lateWaiters.append(continuation)
                return
            }
            effects.add { continuation.resume(returning: transcript) }
        }
    }

    /// The connection is built and resumed outside the lock: the factory and
    /// the transport may call back synchronously.
    private func connect(_ active: RevAILiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        let attached: Bool = withState { _ in
            guard isCurrent(active), active.connection == nil else { return false }
            active.connection = connection
            return true
        }
        guard attached else {
            connection.cancel()
            return
        }
        log("WebSocket connecting")
        connection.resume { [weak self, weak active] in
            guard let self, let active, self.withState({ _ in self.isCurrent(active) }) else { return }
            self.log("WebSocket handshake completed")
        }
        receive(active, connection)
    }
}

// MARK: - Run lifecycle

extension RevAILiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: "Rev.ai") }

    /// Finish callers waiting on the active run, including those held while a
    /// failure is delivered; lets tests observe that a finish has registered
    /// without sleeping.
    var pendingFinishes: Int { withState { _ in run.waiters.count + run.lateWaiters.count } }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout RevAILiveEffects) -> Value) -> Value {
        var effects = RevAILiveEffects()
        let value = lock.withLock { body(&effects) }
        effects.perform()
        return value
    }

    func isCurrent(_ active: RevAILiveRun) -> Bool { active === run && active.phase != .closed }

    /// Retires the run at once, then, outside the lock, publishes the failure
    /// before any finish caller of this run returns: those already waiting and
    /// those that join while it is being delivered. Transcripts already on their
    /// way to the host arrive first: the report waits for them and is released
    /// by the last one to return, on its thread, so no caller blocks on a host
    /// callback. Words a finish had withheld follow, so the host's visible draft
    /// keeps everything the server sent, while finish callers receive confirmed
    /// text only. A callback that starts a new session cannot be touched by
    /// this cleanup: the run is detached, and only its own callers are released.
    func fail(_ active: RevAILiveRun, _ error: Error, _ effects: inout RevAILiveEffects) {
        guard isCurrent(active) else { return }
        let onTranscript = active.onTranscript
        let onError = active.onError
        let finals = active.withheldFinals
        let partial = active.withheldPartial
        let waiters = active.waiters
        let transcript = active.transcript
        active.waiters.removeAll()
        active.deliveringFailure = true
        retire(active, &effects)
        log("Session failed")
        let report = {
            if let onTranscript {
                finals.forEach { onTranscript($0, true) }
                if let partial { onTranscript(partial, false) }
            }
            onError?(error)
            waiters.forEach { $0.resume(returning: transcript) }
            self.withState { effects in self.endFailureDelivery(active, &effects) }
        }
        if active.transcriptsInFlight > 0 {
            active.deferredFailureReport = report
        } else {
            effects.add(report)
        }
    }

    /// A transcript callback returned. The last one out releases a failure
    /// report that was waiting behind it, on this thread and outside the lock.
    func transcriptReturned(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        active.transcriptsInFlight -= 1
        guard active.transcriptsInFlight == 0, let report = active.deferredFailureReport else { return }
        active.deferredFailureReport = nil
        effects.add(report)
    }

    /// The error is out: callers that joined while it was being delivered return.
    private func endFailureDelivery(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        active.deliveringFailure = false
        let late = active.lateWaiters
        let transcript = active.transcript
        active.lateWaiters.removeAll()
        effects.add { late.forEach { $0.resume(returning: transcript) } }
    }

    /// Ends the run for good: its socket is cancelled, admitted audio and its
    /// budget are released, callbacks are dropped and every waiter resumes with
    /// the confirmed transcript.
    func retire(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        let waiters = active.waiters
        let transcript = active.transcript
        active.connection = nil
        active.outgoing.removeAll()
        active.admittedBytes = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        active.waiters.removeAll()
        active.withheldFinals.removeAll()
        active.withheldPartial = nil
        active.onTranscript = nil
        active.onError = nil
        effects.add {
            connection?.cancel()
            waiters.forEach { $0.resume(returning: transcript) }
        }
    }

    /// Arms a deadline owned by `active`. It acts only while that run is still
    /// current, so a late timer cannot touch a stopped or replacement run.
    func after(
        _ seconds: TimeInterval, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects,
        action: @escaping @Sendable (RevAILiveClient, RevAILiveRun, inout RevAILiveEffects) -> Void
    ) {
        let schedule = self.schedule
        effects.add {
            schedule(seconds) { [weak self, weak active] in
                guard let self, let active else { return }
                self.withState { effects in
                    if self.isCurrent(active) { action(self, active, &effects) }
                }
            }
        }
    }

    /// Lifecycle events only: never the URL (it carries the access token),
    /// audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "RevAILiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
