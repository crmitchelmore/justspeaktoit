import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Universal-3.5 Pro's shared streaming client. The transport is replaceable;
/// request construction, turn assembly, PCM framing and shutdown remain shared.
///
/// Settings-derived options reach it through ``LiveClientOptions``: keyterms
/// bias recognition, `postStopFinalizeBudget` bounds the wait for the trailing
/// formatted turn after `ForceEndpoint`, and `stopGracePeriod` holds
/// `Terminate` for the caller's grace after that turn. A finish returns the
/// whole session; the provider's closed utterances are explicit boundaries.
public final class AssemblyAILiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, UtteranceBoundaryStreamingClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    /// A finish drains every admitted frame before `ForceEndpoint`.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Draining, `ForceEndpoint`, the trailing turn and `Terminate` must all
    /// fit in this bound (plus any stop grace).
    static let finishDeadline: TimeInterval = 8
    static var defaultPostStopFinalizeBudget: TimeInterval {
        ModelCatalog.liveCapabilities(for: AssemblyAIModels.universal35ProStreamingID).postStopFinalizeBudget
    }

    let apiKey: String
    let speechModel: String
    let sampleRate: Int
    let keyterms: [String]
    let postStopFinalizeBudget: TimeInterval
    let stopGracePeriod: TimeInterval
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let queue = DispatchQueue(label: "AssemblyAILiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    var run: AssemblyAILiveRun
    private var boundaryCallback: ((String) -> Void)?

    /// Called with each utterance the provider closes, during a finish too.
    public var onUtteranceBoundary: ((String) -> Void)? {
        get { synchronized { boundaryCallback } }
        set { synchronized { boundaryCallback = newValue } }
    }

    /// A stop grace extends the finish beyond the host's default watchdog.
    public var finalisationBudget: TimeInterval? {
        stopGracePeriod > 0 ? Self.finishDeadline + stopGracePeriod : nil
    }

    public convenience init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, session: URLSession? = nil
    ) {
        self.init(apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate, session: session, keyterms: [])
    }

    public convenience init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, session: URLSession? = nil, keyterms: [String]
    ) {
        self.init(
            apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate, session: session,
            keyterms: keyterms, postStopFinalizeBudget: Self.defaultPostStopFinalizeBudget, stopGracePeriod: 0
        )
    }

    public convenience init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, session: URLSession? = nil, keyterms: [String],
        postStopFinalizeBudget: TimeInterval, stopGracePeriod: TimeInterval
    ) {
        let transportSession = session ?? Self.makeSession()
        self.init(
            apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate, keyterms: keyterms,
            postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod,
            makeConnection: { URLSessionStreamingConnection(session: transportSession, request: $0) }
        )
    }

    public init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, keyterms: [String] = [],
        postStopFinalizeBudget: TimeInterval? = nil, stopGracePeriod: TimeInterval = 0,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speechModel = speechModel
        self.sampleRate = sampleRate
        self.keyterms = keyterms
        self.postStopFinalizeBudget = postStopFinalizeBudget.map(Self.sanitized) ?? Self.defaultPostStopFinalizeBudget
        self.stopGracePeriod = Self.sanitized(stopGracePeriod)
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = AssemblyAILiveRun(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Test seam: real-time scheduling with short, explicit stop options.
    convenience init(
        apiKey: String = "test-key",
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000,
        keyterms: [String] = [],
        postStopFinalizeBudget: TimeInterval = 0.1,
        stopGracePeriod: TimeInterval = 0,
        socketFactory: @escaping ConnectionFactory
    ) {
        self.init(
            apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate, keyterms: keyterms,
            postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod,
            makeConnection: socketFactory
        )
    }

    deinit { run.attempt?.connection.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            close(run)
            let active = AssemblyAILiveRun(sampleRate: sampleRate)
            run = active
            active.onTranscript = onTranscript
            active.onError = onError
            guard !apiKey.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "AssemblyAI"), active); return
            }
            guard (1...192_000).contains(sampleRate) else {
                fail(AssemblyAIStreamingError.invalidSampleRate, active); return
            }
            active.phase = .connecting
            connect(active, host: .europe)
        }
    }

    /// Audio waiting for `Begin` keeps the newest five seconds: the oldest
    /// frames make room, as the established client did. Once the session has
    /// begun, a backlog beyond the budget is a stalled transport instead.
    /// Capture chunks are repacked into 100 ms frames, so a chunk need not hold
    /// whole samples: a split sample is completed by the next chunk.
    public func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        synchronized {
            let active = run
            guard active.phase == .connecting || active.phase == .active else { return }
            while !active.budget.admit(data.count) {
                guard active.awaitingBegin, !active.outgoing.isEmpty else { fail(stalledError, active); return }
                active.budget.release(active.outgoing.removeFirst().count)
            }
            active.hasAudio = true
            active.outgoing.append(contentsOf: active.framer.append(data))
            pump(active)
        }
    }

    /// Immediate stop: the socket closes at once and any finish waiting on
    /// this session returns the text received so far. Graceful callers use
    /// `finishAndWait()`.
    public func stop() { synchronized { close(run) } }

    /// The same immediate abort, for hosts that distinguish cancellation.
    public func cancel() { synchronized { close(run) } }

    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), active.attempt != nil else {
                        if active === run { close(active) }
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    if Task.isCancelled {
                        close(active)
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    active.waiters.append(continuation)
                    beginFinish(active)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    /// The current session, or the last one until the next `start()`.
    public func transcriptSnapshot(captureDuration _: TimeInterval) -> StreamingTranscriptSnapshot {
        synchronized { run.assembler.snapshot(terminal: run.phase == .closed) }
    }

    /// Stop sequencing: admitted audio, then `ForceEndpoint`, then the trailing
    /// formatted turn (or its budget), then the stop grace, then `Terminate`.
    /// Once the session has begun a finish always forces the endpoint, so a
    /// turn the provider is still forming is confirmed.
    func beginFinish(_ active: AssemblyAILiveRun) {
        guard isCurrent(active), let attempt = active.attempt else { close(active); return }
        guard active.phase != .finishing else { return }
        // Nothing was admitted and no turn can arrive before `Begin`: there is
        // nothing to finalise, so the socket closes without control frames.
        guard attempt.didBegin || active.hasAudio else { close(active); return }
        active.phase = .finishing
        let held = active.framer.bufferedByteCount
        if let tail = active.framer.finish() {
            guard active.budget.admit(tail.count - held) else { fail(stalledError, active); return }
            active.outgoing.append(tail)
        }
        pump(active)
        after(Self.finishDeadline + stopGracePeriod, active) { client, active in
            if active.ending == .sent { client.close(active) } else { client.fail(client.stalledError, active) }
        }
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "AssemblyAI") }

    func fail(_ error: Error, _ active: AssemblyAILiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        close(active)
        // Publish failure before finish returns. The run is already detached,
        // so an error callback may safely start a replacement session.
        callback?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func close(_ active: AssemblyAILiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let attempt = active.attempt
        active.attempt = nil
        active.outgoing.removeAll()
        active.framer.reset()
        active.budget.reset()
        active.sending = false
        let waiters = active.waiters
        active.waiters.removeAll()
        attempt?.connection.cancel()
        waiters.forEach { $0.resume(returning: active.transcript) }
        active.onTranscript = nil
        active.onError = nil
    }

    func isCurrent(_ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt? = nil) -> Bool {
        active === run && active.phase != .closed && (attempt == nil || active.attempt === attempt)
    }

    func after(_ seconds: TimeInterval, _ active: AssemblyAILiveRun,
               action: @escaping @Sendable (AssemblyAILiveClient, AssemblyAILiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    /// The handshake request for `endpoint`, carrying the session's keyterms.
    func makeRequest(endpoint: AssemblyAIStreamingEndpoint) -> URLRequest? {
        guard let url = AssemblyAIStreamingRequest.url(
            endpoint: endpoint, apiKey: apiKey, sampleRate: sampleRate,
            speechModel: speechModel, keyterms: keyterms
        ) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = true
        #endif
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
