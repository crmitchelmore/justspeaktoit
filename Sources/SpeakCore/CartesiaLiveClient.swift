import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
public final class CartesiaLiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, UtteranceBoundaryStreamingClient, @unchecked Sendable {
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
    /// Exposes this client's finish bound to host lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { timing.finish }
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

    let apiKey: String
    let model: String
    let sampleRate: Int
    private let makeConnection: ConnectionFactory
    let schedule: Scheduler
    let timing: Timing
    let lock = NSLock()
    private(set) var run: CartesiaLiveRun
    /// Kept for the boundary contract; see `onUtteranceBoundary`.
    var boundaryCallback: ((String) -> Void)?

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

    /// `postStopFinalizeBudget` and `stopGracePeriod` come from
    /// ``LiveClientOptions``. The server's normal closure still ends a healthy
    /// finish; they only widen the bound on waiting for it.
    public convenience init(
        apiKey: String,
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        postStopFinalizeBudget: TimeInterval? = nil,
        stopGracePeriod: TimeInterval = 0,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.init(
            apiKey: apiKey, model: model, sampleRate: sampleRate,
            timing: Timing(postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod),
            makeConnection: makeConnection, schedule: schedule
        )
    }

    init(
        apiKey: String,
        model: String,
        sampleRate: Int,
        timing: Timing,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.sampleRate = sampleRate
        self.timing = timing
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = CartesiaLiveRun(sampleRate: sampleRate, ignoredReceiveWindow: timing.ignoredReceiveWindow)
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
                active = CartesiaLiveRun(sampleRate: sampleRate, ignoredReceiveWindow: timing.ignoredReceiveWindow)
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
