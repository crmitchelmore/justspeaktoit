import Foundation

/// Cross-platform Cartesia Ink streaming speech-to-text client.
public final class CartesiaLiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, UtteranceBoundaryStreamingTranscriptionClient,
    @unchecked Sendable {
    public static let apiVersion = "2026-03-01"
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public let finishFlushesBufferedAudio = true

    private static let host = "api.cartesia.ai"
    private static let path = "/stt/turns/websocket"
    private static let defaultSendBudget: TimeInterval = 1.5
    private static let readinessPoll: TimeInterval = 0.01
    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let sendBudget: TimeInterval
    private let postCloseBudget: TimeInterval
    private let stopGracePeriod: TimeInterval
    private let socketFactory: LiveWebSocketFactory
    private let retainedSession: URLSession?
    private let queue = DispatchQueue(label: "com.speak.core.cartesia.live")
    private let callbackQueue = DispatchQueue(label: "com.speak.core.cartesia.live.callbacks")
    private var run: Run?
    private var lastAssembler: CartesiaTranscriptAssembler?
    private var lastFinishedTranscript: String?
    private var callbackGeneration = UUID()
    private var boundaryCallback: ((String) -> Void)?

    /// The former Mac controller emitted no polish boundaries. Conformance
    /// suppresses the shared controller's inferred final boundary while this
    /// callback intentionally stays silent.
    public var onUtteranceBoundary: ((String) -> Void)? {
        get { queue.sync { boundaryCallback } }
        set { queue.sync { boundaryCallback = newValue } }
    }

    public convenience init(
        apiKey: String,
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, sampleRate: sampleRate, session: session,
            postStopFinalizeBudget: ModelCatalog.liveCapabilities(
                for: "cartesia/ink-2-streaming"
            ).postStopFinalizeBudget,
            stopGracePeriod: 0
        )
    }

    public init(
        apiKey: String,
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        session: URLSession = .shared,
        postStopFinalizeBudget: TimeInterval,
        stopGracePeriod: TimeInterval
    ) {
        self.apiKey = apiKey
        self.model = model
        self.sampleRate = sampleRate
        sendBudget = Self.defaultSendBudget
        postCloseBudget = Self.sanitized(postStopFinalizeBudget)
        self.stopGracePeriod = Self.sanitized(stopGracePeriod)
        retainedSession = session
        socketFactory = { request in
            URLSessionLiveWebSocketTransport(task: session.webSocketTask(with: request))
        }
    }

    init(
        apiKey: String = "test-key",
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        sendBudget: TimeInterval = 0.1,
        postStopFinalizeBudget: TimeInterval = 0.05,
        stopGracePeriod: TimeInterval = 0,
        socketFactory: @escaping LiveWebSocketFactory
    ) {
        self.apiKey = apiKey
        self.model = model
        self.sampleRate = sampleRate
        self.sendBudget = Self.sanitized(sendBudget)
        postCloseBudget = Self.sanitized(postStopFinalizeBudget)
        self.stopGracePeriod = Self.sanitized(stopGracePeriod)
        self.socketFactory = socketFactory
        retainedSession = nil
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if let previous = self.run { self.complete(previous, closeCode: .goingAway) }
            self.lastAssembler = nil
            self.lastFinishedTranscript = nil
            let next = Run(
                sampleRate: self.sampleRate,
                onTranscript: onTranscript,
                onError: onError
            )
            self.run = next
            self.callbackGeneration = next.id
            self.connect(next)
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let run = self.run, !run.finishing else { return }
            for frame in run.framer.append(audioData) { self.admit(frame, to: run) }
            self.trimStartupAudio(run)
            self.activateTransportIfReady(run)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, let run = self.run else { return }
            self.complete(run, closeCode: .goingAway)
        }
    }

    public func finishAndWait() async -> String? {
        let deliveryQueue = callbackQueue
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    deliveryQueue.async { continuation.resume(returning: nil) }
                    return
                }
                guard let run = self.run else {
                    let retained = self.lastFinishedTranscript
                    deliveryQueue.async { continuation.resume(returning: retained) }
                    return
                }
                run.finishWaiters.append(continuation)
                guard !run.finishing else { return }
                run.finishing = true
                if let residual = run.framer.finish() { self.admit(residual, to: run) }
                self.activateTransportIfReady(run)
                self.queue.asyncAfter(deadline: .now() + self.sendBudget) { [weak self, weak run] in
                    guard let self, let run, self.isCurrent(run), !run.closeSent else { return }
                    self.fail(run, description: "Cartesia audio drain timed out.")
                }
                self.admitCloseWhenDrained(run)
            }
        }
    }

    public func transcriptSnapshot(captureDuration _: TimeInterval) -> StreamingTranscriptSnapshot {
        queue.sync {
            if let run { return run.assembler.snapshot(terminal: run.completed) }
            return lastAssembler?.snapshot(terminal: true) ?? StreamingTranscriptSnapshot()
        }
    }
}

extension CartesiaLiveClient {
    func isCurrent(_ candidate: Run) -> Bool {
        run === candidate && !candidate.completed
    }

    func connect(_ run: Run) {
        guard isCurrent(run), let request = makeRequest() else {
            fail(run, error: StreamingClientError.invalidURL)
            return
        }
        let socket = socketFactory(request)
        run.socket = socket
        run.socketID = UUID()
        socket.resume()
        receive(run, socket: socket, socketID: run.socketID)
        activateTransportIfReady(run)
        pollTransportReadiness(run)
    }

    func makeRequest() -> URLRequest? {
        guard let url = Self.webSocketURL(model: model, sampleRate: sampleRate) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        return request
    }

    static func webSocketURL(model: String, sampleRate: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "cartesia_version", value: apiVersion)
        ]
        return components.url
    }

    func pollTransportReadiness(_ run: Run) {
        guard isCurrent(run), !run.transportReady else { return }
        queue.asyncAfter(deadline: .now() + Self.readinessPoll) { [weak self, weak run] in
            guard let self, let run, self.isCurrent(run), !run.transportReady else { return }
            self.activateTransportIfReady(run)
            self.pollTransportReadiness(run)
        }
    }

    func activateTransportIfReady(_ run: Run) {
        guard isCurrent(run), let socket = run.socket, socket.state == .running else { return }
        if !run.transportReady {
            run.transportReady = true
            for frame in run.startupFrames { enqueueAudio(frame, to: run) }
            run.startupFrames.removeAll(keepingCapacity: false)
            run.startupBytes = 0
        }
        pump(run)
        if run.finishing { admitCloseWhenDrained(run) }
    }

    func admit(_ frame: Data, to run: Run) {
        guard isCurrent(run), !frame.isEmpty else { return }
        if run.transportReady {
            enqueueAudio(frame, to: run)
        } else {
            run.startupFrames.append(frame)
            run.startupBytes += frame.count
        }
    }

    func enqueueAudio(_ frame: Data, to run: Run) {
        guard isCurrent(run) else { return }
        let limit = max(0, sampleRate * 2 * 2)
        guard run.outboundAudioBytes + frame.count <= limit else {
            fail(run, description: "Cartesia outbound audio backlog exceeded two seconds.")
            return
        }
        run.outbound.append(.audio(frame))
        run.outboundAudioBytes += frame.count
        pump(run)
    }

    func trimStartupAudio(_ run: Run) {
        guard !run.transportReady else { return }
        let limit = max(0, sampleRate * 2 * 2)
        while run.startupBytes + run.framer.bufferedByteCount > limit,
              !run.startupFrames.isEmpty {
            run.startupBytes -= run.startupFrames.removeFirst().count
        }
    }

    func pump(_ run: Run) {
        guard isCurrent(run), run.transportReady, !run.sending,
              let socket = run.socket, !run.outbound.isEmpty else { return }
        let item = run.outbound.removeFirst()
        run.sending = true
        let socketID = run.socketID
        socket.send(item.message) { [weak self, weak run] error in
            self?.queue.async { [weak self, weak run] in
                guard let self, let run, self.isCurrent(run), run.socketID == socketID else { return }
                run.sending = false
                if case .audio(let data) = item { run.outboundAudioBytes -= data.count }
                if let error {
                    self.fail(run, error: self.mapConnectionError(error))
                    return
                }
                if case .close = item {
                    run.closeSent = true
                    self.scheduleFinishDeadline(run)
                }
                self.pump(run)
                self.admitCloseWhenDrained(run)
            }
        }
    }

    func admitCloseWhenDrained(_ run: Run) {
        guard isCurrent(run), run.finishing, run.transportReady,
              !run.closeAdmitted, !run.sending, run.outbound.isEmpty else { return }
        run.closeAdmitted = true
        run.outbound.append(.close)
        pump(run)
    }

    func scheduleFinishDeadline(_ run: Run) {
        let delay = postCloseBudget + stopGracePeriod
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak run] in
            guard let self, let run, self.isCurrent(run), run.finishing else { return }
            self.complete(run, closeCode: .normalClosure)
        }
    }

    func receive(_ run: Run, socket: LiveWebSocketTransport, socketID: UUID) {
        socket.receive { [weak self, weak run] result in
            self?.queue.async { [weak self, weak run] in
                guard let self, let run, self.isCurrent(run), run.socketID == socketID else { return }
                switch result {
                case .success(let message):
                    self.handle(message, run: run) { [weak self, weak run] in
                        self?.queue.async { [weak self, weak run] in
                            guard let self, let run, self.isCurrent(run),
                                  run.socketID == socketID else { return }
                            self.receive(run, socket: socket, socketID: socketID)
                        }
                    }
                case .failure(let error):
                    if run.finishing, run.closeAdmitted, socket.closeCode == .normalClosure {
                        self.complete(run, closeCode: .normalClosure)
                    } else if WebSocketErrorFilter.shouldIgnore(error) {
                        return
                    } else {
                        self.fail(run, error: self.mapConnectionError(error))
                    }
                }
            }
        }
    }

    func handle(
        _ message: URLSessionWebSocketTask.Message,
        run: Run,
        completion: @escaping @Sendable () -> Void
    ) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text else {
            completion()
            return
        }
        if let error = Self.providerError(from: text) {
            fail(run, error: error)
            completion()
            return
        }
        guard let event = Self.transcriptEvent(from: text) else {
            completion()
            return
        }
        _ = run.assembler.consume(event)
        let consumesTrailingFinal = event.isFinal && run.finishing
        callbackQueue.async { [weak self, run] in
            guard let self,
                  self.queue.sync(execute: { self.callbackGeneration == run.id }) else {
                completion()
                return
            }
            if !consumesTrailingFinal { run.onTranscript(event.text, event.isFinal) }
            completion()
        }
    }

    func fail(_ run: Run, description: String) {
        fail(run, error: NSError(
            domain: "Cartesia", code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        ))
    }

    func fail(_ run: Run, error: Error) {
        guard isCurrent(run) else { return }
        let callback = run.onError
        callbackQueue.async { [weak self, run] in
            guard let self,
                  self.queue.sync(execute: { self.callbackGeneration == run.id }) else { return }
            callback(error)
        }
        complete(run, closeCode: .goingAway)
    }

    func complete(_ run: Run, closeCode: URLSessionWebSocketTask.CloseCode) {
        guard !run.completed else { return }
        run.completed = true
        run.socket?.cancel(with: closeCode, reason: nil)
        run.socket = nil
        let transcript = run.assembler.completeText
        let result = transcript.isEmpty ? nil : transcript
        let waiters = run.finishWaiters
        run.finishWaiters.removeAll()
        if self.run === run {
            lastAssembler = run.assembler
            if run.finishing { lastFinishedTranscript = result }
            self.run = nil
        }
        callbackQueue.async { waiters.forEach { $0.resume(returning: result) } }
    }
}
