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
/// mono is repacked into 100 ms frames and sent as one binary frame at a time
/// once the socket has actually opened; until then the newest two seconds wait,
/// the oldest making room. A graceful finish drains every admitted frame,
/// sends exactly one `{"type":"close"}` and reads the remaining results until
/// the server's normal closure or the post-stop budget, whichever comes first,
/// then returns the whole session. The transport is injected
/// (`URLSessionStreamingConnection` on Apple, WinHTTP on Windows); framing,
/// admission and lifecycle stay here so the platforms cannot drift.
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

    /// A finish must have drained its admitted audio, including any wait for
    /// the handshake, and sent `close` within this bound.
    public static let finishBudget: TimeInterval = 1.5
    /// Exposes this client's finish bound to host lifecycle watchdogs: the
    /// drain, then the post-stop budget and any stop grace after `close`.
    public var finalisationBudget: TimeInterval? { timing.drain + timing.postClose }
    /// The handshake must complete within this bound of `start()`.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Seconds of PCM that may wait for the socket to open, the newest kept,
    /// and that may be queued or in flight once it has.
    static let bufferedAudioSeconds: Double = 2

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
    /// ``LiveClientOptions`` and bound the read after `close`; the server's
    /// normal closure ends a healthy finish sooner. Without a budget the
    /// catalogue's Ink-2 post-stop budget applies.
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

    /// Capture chunks are repacked into 100 ms frames, so a chunk need not hold
    /// whole samples. While the socket opens, including before the first
    /// `start()`, the newest `bufferedAudioSeconds` wait and the oldest frames
    /// make room. Once it has opened, admission is bounded by the same amount
    /// queued or in flight, and exceeding it is a stalled transport.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let outbound: CartesiaOutbound? = withState { effects in
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming else {
                return nil
            }
            for frame in active.framer.append(audioData) {
                guard admit(frame, active, &effects) else { return nil }
            }
            trimStartupAudio(active)
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }

    /// Immediate teardown; `cancel()` is the same path. A pending handshake,
    /// drain or finish is aborted at once and every waiter resumes with the
    /// text received so far.
    public func stop() { withState { retire(run, &$0) } }

    public func cancel() { stop() }

    /// Drains every admitted frame and the framer's padded tail, sends
    /// `{"type":"close"}` once, then reads results until the server's normal
    /// closure or the post-stop budget (plus any stop grace). Returns the whole
    /// session transcript, confirmed turns and the open turn's words, or `nil`
    /// when nothing has words; turns that end during the finish are folded into
    /// it rather than also delivered through `onTranscript`. Later calls return
    /// the same result until the next `start()`. A drain that cannot send
    /// `close` within `finishBudget`, or a failed stream, publishes its error
    /// before returning, also to callers that join while the error is being
    /// delivered. Concurrent callers share one outcome; cancelling the calling
    /// task aborts the session.
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
