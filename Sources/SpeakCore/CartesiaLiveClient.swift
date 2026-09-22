import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Cartesia Live Client (portable, injected transport)

/// Shared Cartesia Ink-2 streaming client. The iOS live path reaches it through
/// `LiveTranscriptionClientFactory` and Windows through `DesktopLiveTranscription`;
/// the macOS app still records through its own `CartesiaLiveController` and
/// `CartesiaLiveTranscriber` and does not use this client yet.
///
/// One `/stt/turns/websocket` socket per run (see `CartesiaLiveProtocol`). PCM16
/// mono is admitted synchronously into a bounded queue and sent as one binary
/// frame at a time once the socket has actually opened. A graceful finish
/// drains every admitted frame, sends `{"type":"close"}` and waits, inside one
/// bounded budget, for the server to close the stream after flushing its
/// remaining events. The transport is injected (`URLSessionStreamingConnection`
/// on Apple, WinHTTP on Windows); framing, admission and lifecycle stay here so
/// the platforms cannot drift.
///
/// State lives under one lock that is never held across a transport call, a
/// host callback, a scheduler call or a continuation resume.
public final class CartesiaLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Each `turn.end` is one completed turn, delivered once.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `close` has the model process every buffered sample, so words can still
    /// arrive after the last frame: a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// One deadline bounds a graceful finish: any wait for the handshake, the
    /// drain of admitted audio, `close` and the server's closure. A healthy
    /// stream ends on the closure itself; nothing sleeps.
    public static let finishBudget: TimeInterval = 8
    /// Exposes `finishBudget` to host lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { Self.finishBudget }
    /// A finish that lands before the handshake waits at most this long for it.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// The handshake must complete within this bound of `start()`.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Seconds of PCM that may be queued or in flight, including audio held
    /// while the socket opens.
    static let bufferedAudioSeconds: Double = StreamingAudioPreroll.defaultBudgetSeconds
    /// Frames that may be queued or in flight, alongside the byte bound.
    static let maximumQueuedFrames = 256

    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let lock = NSLock()
    private(set) var run: CartesiaLiveRun

    public convenience init(
        apiKey: String,
        model: String = "ink-2",
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
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = CartesiaLiveRun(sampleRate: sampleRate)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let opening: (CartesiaLiveRun, URLRequest)? = withState { effects in
            let active: CartesiaLiveRun
            if run.phase == .idle {
                // Audio offered before the first start is already queued, in order.
                active = run
            } else {
                retire(run, &effects)
                active = CartesiaLiveRun(sampleRate: sampleRate)
                run = active
            }
            active.phase = .connecting
            active.onTranscript = onTranscript
            active.onError = onError
            if let failure = active.pendingFailure {
                fail(active, failure, &effects)
                return nil
            }
            guard !apiKey.isEmpty else {
                fail(active, StreamingClientError.missingAPIKey(provider: "Cartesia"), &effects)
                return nil
            }
            guard let request = CartesiaLiveProtocol.webSocketRequest(
                apiKey: apiKey, model: model, sampleRate: sampleRate
            ) else {
                fail(active, StreamingClientError.invalidURL, &effects)
                return nil
            }
            after(Self.readyDeadline, active, &effects) { client, active, effects in
                if !active.opened { client.fail(active, CartesiaStreamingError.sessionNotReady, &effects) }
            }
            return (active, request)
        }
        guard let opening else { return }
        connect(opening.0, request: opening.1)
    }

    /// Admission is synchronous and bounded: at most `bufferedAudioSeconds` of
    /// PCM and `maximumQueuedFrames` frames may be queued or in flight,
    /// including audio held while the socket opens. Exceeding either is
    /// reported as a stalled transport instead of silently trimming the
    /// recording, and a frame of partial samples is refused before it could
    /// misalign every later sample. Audio before the first `start()` is held
    /// under the same bounds and a failure there is reported by `start()`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let outbound: CartesiaOutbound? = withState { effects in
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming,
                  active.pendingFailure == nil else { return nil }
            let failure: Error?
            if !audioData.count.isMultiple(of: 2) {
                failure = CartesiaStreamingError.invalidPCM
            } else if active.admittedFrames >= Self.maximumQueuedFrames
                || active.admittedBytes + audioData.count > active.maximumBytes {
                failure = stalledError
            } else {
                failure = nil
            }
            guard let failure else {
                active.outgoing.append(audioData)
                active.admittedBytes += audioData.count
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
    /// text confirmed so far.
    public func stop() { withState { retire(run, &$0) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, sends `{"type":"close"}` and waits for the
    /// server to close the stream, all inside `finishBudget`. Returns the whole
    /// session transcript, or `nil` when no turn produced words; turns that end
    /// during the finish are folded into it rather than also delivered through
    /// `onTranscript`. A finish that cannot reach that documented end publishes
    /// its error before returning the confirmed text, also to callers that join
    /// while the error is being delivered. Concurrent callers share one outcome;
    /// cancelling the calling task aborts the session.
    public func finishAndWait() async -> String? {
        let active: CartesiaLiveRun = withState { _ in run }
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
        _ active: CartesiaLiveRun, _ continuation: CheckedContinuation<String?, Never>,
        _ effects: inout CartesiaLiveEffects
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
    private func connect(_ active: CartesiaLiveRun, request: URLRequest) {
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
            guard let self, let active else { return }
            self.markOpened(active)
        }
        receive(active, connection)
    }

    private func markOpened(_ active: CartesiaLiveRun) {
        let outbound: CartesiaOutbound? = withState { effects in
            guard recordOpen(active) else { return nil }
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }
}

// MARK: - Run lifecycle

extension CartesiaLiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: "Cartesia") }

    /// Finish callers waiting on the active run, including those held while a
    /// failure is delivered; lets tests observe that a finish has registered
    /// without sleeping.
    var pendingFinishes: Int { withState { _ in run.waiters.count + run.lateWaiters.count } }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout CartesiaLiveEffects) -> Value) -> Value {
        var effects = CartesiaLiveEffects()
        let value = lock.withLock { body(&effects) }
        effects.perform()
        return value
    }

    func isCurrent(_ active: CartesiaLiveRun) -> Bool { active === run && active.phase != .closed }

    /// Records the handshake, from the transport or the `connected` frame.
    /// Returns whether this call opened the run.
    func recordOpen(_ active: CartesiaLiveRun) -> Bool {
        guard isCurrent(active), active.connection != nil, !active.opened else { return false }
        active.opened = true
        if active.phase == .connecting { active.phase = .streaming }
        log("WebSocket handshake completed")
        return true
    }

    /// Retires the run, then, outside the lock, publishes the failure before any
    /// finish caller of this run returns: those already waiting and those that
    /// join while it is being delivered. Words a finish had withheld are
    /// delivered first, so the host's visible draft keeps everything the server
    /// sent, while finish callers receive confirmed text only. A callback that
    /// starts a new session cannot be touched by this cleanup: the run is
    /// already detached, and only its own late callers are released after it.
    func fail(_ active: CartesiaLiveRun, _ error: Error, _ effects: inout CartesiaLiveEffects) {
        guard isCurrent(active) else { return }
        let onTranscript = active.onTranscript
        let onError = active.onError
        let finals = active.withheldFinals
        let draft = active.withheldDraft
        let waiters = active.waiters
        let transcript = active.transcript
        active.waiters.removeAll()
        active.deliveringFailure = true
        retire(active, &effects)
        log("Session failed")
        effects.add {
            if let onTranscript {
                finals.forEach { onTranscript($0, true) }
                if let draft { onTranscript(draft, false) }
            }
            onError?(error)
            waiters.forEach { $0.resume(returning: transcript) }
            self.withState { effects in self.endFailureDelivery(active, &effects) }
        }
    }

    /// The error is out: callers that joined while it was being delivered return.
    private func endFailureDelivery(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        active.deliveringFailure = false
        let late = active.lateWaiters
        let transcript = active.transcript
        active.lateWaiters.removeAll()
        effects.add { late.forEach { $0.resume(returning: transcript) } }
    }

    /// Ends the run for good: its socket is cancelled, admitted audio and its
    /// budget are released, callbacks are dropped and every waiter resumes with
    /// the confirmed transcript.
    func retire(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
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
        active.withheldDraft = nil
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
        _ seconds: TimeInterval, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects,
        action: @escaping @Sendable (CartesiaLiveClient, CartesiaLiveRun, inout CartesiaLiveEffects) -> Void
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

    /// Lifecycle events only: never a key, audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "CartesiaLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
