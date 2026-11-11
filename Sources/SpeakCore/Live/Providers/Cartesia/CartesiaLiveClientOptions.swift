import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Stop options, the result snapshot and the boundary contract for the shared
// Cartesia client, kept beside its lifecycle so the client file stays focused.
extension CartesiaLiveClient {
    /// Per-client bounds. Production uses the documented statics and the
    /// catalogue's post-stop budget; a caller's ``LiveClientOptions`` set the
    /// post-stop budget and add their stop grace after `close`.
    struct Timing: Sendable {
        /// Each send must complete within this bound.
        var send: TimeInterval = CartesiaLiveClient.sendDeadline
        /// The drain, including any wait for the handshake, must deliver
        /// `close` within this bound.
        var drain: TimeInterval = CartesiaLiveClient.finishBudget
        /// After `close`, results are read until the server's normal closure
        /// or until this bound, which then completes the finish.
        var postClose: TimeInterval = CartesiaLiveClient.defaultPostStopFinalizeBudget
        /// How long consecutive spurious ENOTCONN receive failures are retried.
        var ignoredReceiveWindow: TimeInterval = IgnoredReceiveFailureWindow.defaultWindow

        init() {}

        init(postStopFinalizeBudget: TimeInterval?, stopGracePeriod: TimeInterval) {
            let budget = postStopFinalizeBudget.map(CartesiaLiveClient.sanitized)
                ?? CartesiaLiveClient.defaultPostStopFinalizeBudget
            postClose = budget + CartesiaLiveClient.sanitized(stopGracePeriod)
        }
    }

    /// The catalogue's post-stop budget for Ink-2 streaming.
    static var defaultPostStopFinalizeBudget: TimeInterval {
        sanitized(ModelCatalog.liveCapabilities(for: "cartesia/ink-2-streaming").postStopFinalizeBudget)
    }

    /// The settings-aware initializer the live-client factory uses.
    public convenience init(
        apiKey: String,
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        session: URLSession = .shared,
        postStopFinalizeBudget: TimeInterval,
        stopGracePeriod: TimeInterval
    ) {
        self.init(
            apiKey: apiKey, model: model, sampleRate: sampleRate,
            postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    /// Test seam: real-time scheduling with short, explicit bounds. The send
    /// budget bounds each send, the drain to `close` and the spurious-disconnect
    /// retries; the post-close budget and grace bound the read after `close`.
    convenience init(
        apiKey: String = "test-key",
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        sendBudget: TimeInterval = 0.1,
        postStopFinalizeBudget: TimeInterval = 0.05,
        stopGracePeriod: TimeInterval = 0,
        socketFactory: @escaping ConnectionFactory
    ) {
        var timing = Timing()
        timing.send = Self.sanitized(sendBudget)
        timing.drain = timing.send
        timing.postClose = Self.sanitized(postStopFinalizeBudget) + Self.sanitized(stopGracePeriod)
        timing.ignoredReceiveWindow = timing.send
        self.init(
            apiKey: apiKey, model: model, sampleRate: sampleRate, timing: timing,
            makeConnection: socketFactory,
            schedule: { seconds, action in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
            }
        )
    }

    /// Cartesia reports no polish boundaries, and neither did the Mac
    /// controller. Conforming keeps hosts from inferring one from each final,
    /// while this callback deliberately stays silent.
    public var onUtteranceBoundary: ((String) -> Void)? {
        get { lock.withLock { boundaryCallback } }
        set { lock.withLock { boundaryCallback = newValue } }
    }

    /// Confirmed turns and the open turn's words for the current session, or
    /// for the last one until the next `start()`.
    public func transcriptSnapshot(captureDuration _: TimeInterval) -> StreamingTranscriptSnapshot {
        withState { _ in run.snapshot }
    }

    /// The handshake request this client opens.
    func makeRequest() -> URLRequest? {
        CartesiaLiveProtocol.webSocketRequest(apiKey: apiKey, model: model, sampleRate: sampleRate)
    }

    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
