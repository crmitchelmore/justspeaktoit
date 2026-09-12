// swiftlint:disable file_length
import Foundation

/// Cross-platform AssemblyAI Universal-3.5 Pro Streaming v3 client.
public final class AssemblyAILiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, UtteranceBoundaryStreamingTranscriptionClient,
    @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public let finishFlushesBufferedAudio = true

    private static let beginTimeout: TimeInterval = 8
    private static let audioDrainTimeout: TimeInterval = 1.5
    private static let terminationTimeout: TimeInterval = 3
    private let apiKey: String
    private let speechModel: String
    private let sampleRate: Int
    private let keyterms: [String]
    private let postStopFinalizeBudget: TimeInterval
    private let stopGracePeriod: TimeInterval
    private let socketFactory: LiveWebSocketFactory
    private let retainedSession: URLSession?
    private let queue = DispatchQueue(label: "com.speak.core.assemblyai.live")
    private let callbackQueue = DispatchQueue(label: "com.speak.core.assemblyai.live.callbacks")
    private var run: Run?
    private var lastAssembler: AssemblyAIStreamingTranscriptAssembler?
    private var callbackGeneration = UUID()
    private var boundaryCallback: ((String) -> Void)?

    public var onUtteranceBoundary: ((String) -> Void)? {
        get { queue.sync { boundaryCallback } }
        set { queue.sync { boundaryCallback = newValue } }
    }

    public convenience init(
        apiKey: String,
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000,
        session: URLSession? = nil
    ) {
        self.init(
            apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate,
            session: session, keyterms: []
        )
    }

    public convenience init(
        apiKey: String,
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000,
        session: URLSession? = nil,
        keyterms: [String]
    ) {
        self.init(
            apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate,
            session: session, keyterms: keyterms,
            postStopFinalizeBudget: ModelCatalog.liveCapabilities(
                for: AssemblyAIModels.universal35ProStreamingID
            ).postStopFinalizeBudget,
            stopGracePeriod: 0
        )
    }

    public init(
        apiKey: String,
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000,
        session: URLSession? = nil,
        keyterms: [String],
        postStopFinalizeBudget: TimeInterval,
        stopGracePeriod: TimeInterval
    ) {
        let retained = session ?? AssemblyAILiveClient.makeSession()
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speechModel = speechModel
        self.sampleRate = sampleRate
        self.keyterms = keyterms
        self.postStopFinalizeBudget = Self.sanitized(postStopFinalizeBudget)
        self.stopGracePeriod = Self.sanitized(stopGracePeriod)
        retainedSession = retained
        socketFactory = { request in
            URLSessionLiveWebSocketTransport(task: retained.webSocketTask(with: request))
        }
    }

    init(
        apiKey: String = "test-key",
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000,
        keyterms: [String] = [],
        postStopFinalizeBudget: TimeInterval = 0.1,
        stopGracePeriod: TimeInterval = 0,
        socketFactory: @escaping LiveWebSocketFactory
    ) {
        self.apiKey = apiKey
        self.speechModel = speechModel
        self.sampleRate = sampleRate
        self.keyterms = keyterms
        self.postStopFinalizeBudget = Self.sanitized(postStopFinalizeBudget)
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
            let next = Run(
                sampleRate: self.sampleRate,
                onTranscript: onTranscript,
                onError: onError
            )
            self.callbackGeneration = next.id
            self.run = next
            self.connect(next, endpoint: .europe)
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let run = self.run, !run.finishing else { return }
            for frame in run.framer.append(audioData) { self.admit(frame, to: run) }
            self.trimPreBeginAudio(run)
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
                guard let self, let run = self.run else {
                    deliveryQueue.async {
                        continuation.resume(returning: nil)
                    }
                    return
                }
                run.finishWaiters.append(continuation)
                guard !run.finishing else { return }
                run.finishing = true
                guard run.begun else {
                    self.complete(run, closeCode: .normalClosure)
                    return
                }
                if let residual = run.framer.finish() { self.admit(residual, to: run) }
                run.outbound.append(.control(#"{"type":"ForceEndpoint"}"#))
                self.pump(run)
                self.queue.asyncAfter(deadline: .now() + Self.audioDrainTimeout) { [weak self, weak run] in
                    guard let self, let run, self.isCurrent(run), !run.forceSent else { return }
                    self.fail(run, description: "AssemblyAI audio drain timed out.")
                }
            }
        }
    }

    public func transcriptSnapshot(captureDuration _: TimeInterval) -> StreamingTranscriptSnapshot {
        queue.sync {
            if let run {
                return run.assembler.snapshot(terminal: run.completed)
            }
            return lastAssembler?.snapshot(terminal: true) ?? StreamingTranscriptSnapshot()
        }
    }
}

extension AssemblyAILiveClient {
    final class Run: @unchecked Sendable {
        let id = UUID()
        let onTranscript: (String, Bool) -> Void
        let onError: (Error) -> Void
        var socket: LiveWebSocketTransport?
        var socketID = UUID()
        var endpoint: AssemblyAIStreamingEndpoint = .europe
        var attemptedFallback = false
        var begun = false
        var finishing = false
        var completed = false
        var sending = false
        var forceSent = false
        var terminationAdmitted = false
        var finalObservedAfterFinish = false
        var outbound: [Outbound] = []
        var preBeginFrames: [Data] = []
        var preBeginBytes = 0
        var outboundAudioBytes = 0
        var framer: AssemblyAIPCMFramer
        var assembler = AssemblyAIStreamingTranscriptAssembler()
        var finishWaiters: [CheckedContinuation<String?, Never>] = []

        init(
            sampleRate: Int,
            onTranscript: @escaping (String, Bool) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            framer = AssemblyAIPCMFramer(sampleRate: sampleRate)
            self.onTranscript = onTranscript
            self.onError = onError
        }
    }

    enum Outbound {
        case audio(Data)
        case control(String)

        var message: URLSessionWebSocketTask.Message {
            switch self {
            case .audio(let data): return .data(data)
            case .control(let text): return .string(text)
            }
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    func isCurrent(_ candidate: Run) -> Bool {
        run === candidate && !candidate.completed
    }

    func connect(_ run: Run, endpoint: AssemblyAIStreamingEndpoint) {
        guard isCurrent(run), let request = makeRequest(endpoint: endpoint) else {
            fail(run, description: "Invalid AssemblyAI streaming URL.")
            return
        }
        let socket = socketFactory(request)
        let socketID = UUID()
        run.socket = socket
        run.socketID = socketID
        run.endpoint = endpoint
        socket.resume()
        receive(run, socket: socket, socketID: socketID)
        queue.asyncAfter(deadline: .now() + Self.beginTimeout) { [weak self, weak run] in
            guard let self, let run, self.isCurrent(run), !run.begun,
                  run.socketID == socketID else { return }
            if !self.fallback(run, failedSocket: socket) {
                self.fail(run, description: "AssemblyAI session did not start (Begin timeout).")
            }
        }
    }

    func makeRequest(endpoint: AssemblyAIStreamingEndpoint) -> URLRequest? {
        guard let url = AssemblyAIStreamingRequest.url(
            endpoint: endpoint, apiKey: apiKey, sampleRate: sampleRate,
            speechModel: speechModel, keyterms: keyterms
        ) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    func admit(_ frame: Data, to run: Run) {
        guard !frame.isEmpty else { return }
        if run.begun {
            let limit = max(0, sampleRate * 2 * 5)
            guard run.outboundAudioBytes + frame.count <= limit else {
                fail(run, description: "AssemblyAI outbound audio backlog exceeded five seconds.")
                return
            }
            run.outbound.append(.audio(frame))
            run.outboundAudioBytes += frame.count
            pump(run)
            return
        }
        run.preBeginFrames.append(frame)
        run.preBeginBytes += frame.count
        let limit = max(0, sampleRate * 2 * 5)
        while run.preBeginBytes > limit, !run.preBeginFrames.isEmpty {
            run.preBeginBytes -= run.preBeginFrames.removeFirst().count
        }
    }

    func trimPreBeginAudio(_ run: Run) {
        guard !run.begun else { return }
        let limit = max(0, sampleRate * 2 * 5)
        while run.preBeginBytes + run.framer.bufferedByteCount > limit,
              !run.preBeginFrames.isEmpty {
            run.preBeginBytes -= run.preBeginFrames.removeFirst().count
        }
    }

    func pump(_ run: Run) {
        guard isCurrent(run), run.begun, !run.sending,
              let socket = run.socket, !run.outbound.isEmpty else { return }
        let item = run.outbound.removeFirst()
        run.sending = true
        let socketID = run.socketID
        socket.send(item.message) { [weak self, weak run] error in
            self?.queue.async { [weak self, weak run] in
                guard let self, let run, self.isCurrent(run), run.socketID == socketID else { return }
                run.sending = false
                if case .audio(let data) = item {
                    run.outboundAudioBytes -= data.count
                }
                if let error {
                    self.fail(run, error: error)
                    return
                }
                if case .control(let text) = item, text.contains("ForceEndpoint") {
                    run.forceSent = true
                    self.waitForFinal(run)
                } else if case .control(let text) = item, text.contains("Terminate") {
                    self.scheduleTerminationTimeout(run)
                }
                self.pump(run)
            }
        }
    }

    func waitForFinal(_ run: Run) {
        if run.finalObservedAfterFinish {
            scheduleGrace(run)
            return
        }
        queue.asyncAfter(deadline: .now() + postStopFinalizeBudget) { [weak self, weak run] in
            guard let self, let run, self.isCurrent(run), run.finishing else { return }
            self.scheduleGrace(run)
        }
    }

    func scheduleGrace(_ run: Run) {
        guard !run.completed, !run.terminationAdmitted else { return }
        run.terminationAdmitted = true
        queue.asyncAfter(deadline: .now() + stopGracePeriod) { [weak self, weak run] in
            guard let self, let run, self.isCurrent(run) else { return }
            run.outbound.append(.control(#"{"type":"Terminate"}"#))
            self.pump(run)
            self.scheduleTerminationTimeout(run)
        }
    }

    func scheduleTerminationTimeout(_ run: Run) {
        queue.asyncAfter(deadline: .now() + Self.terminationTimeout) { [weak self, weak run] in
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
                    self.handle(message, run: run)
                    if self.isCurrent(run), run.socketID == socketID {
                        self.receive(run, socket: socket, socketID: socketID)
                    }
                case .failure(let error):
                    if WebSocketErrorFilter.shouldIgnore(error) {
                        self.receive(run, socket: socket, socketID: socketID)
                    } else if !self.fallback(run, failedSocket: socket) {
                        self.fail(run, error: error)
                    }
                }
            }
        }
    }

    func fallback(_ run: Run, failedSocket: LiveWebSocketTransport) -> Bool {
        guard !run.begun, !run.finishing, !run.attemptedFallback else { return false }
        run.attemptedFallback = true
        failedSocket.cancel(with: .goingAway, reason: nil)
        connect(run, endpoint: run.endpoint == .europe ? .global : .europe)
        return true
    }

    func handle(_ message: URLSessionWebSocketTask.Message, run: Run) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AssemblyAIEnvelope.self, from: data) else { return }
        switch envelope.type ?? (envelope.turn_order == nil ? "" : "Turn") {
        case "Begin": handleBegin(run)
        case "Turn":
            guard let turn = try? JSONDecoder().decode(AssemblyAIStreamingTurn.self, from: data),
                  let update = run.assembler.consume(turn) else { return }
            if update.finalizedTurn {
                if run.finishing { run.finalObservedAfterFinish = true }
            }
            let utterance = turn.utterance?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let boundary = utterance?.isEmpty == false ? boundaryCallback : nil
            let consumesTrailingFinal = update.finalizedTurn && run.finishing
            callbackQueue.async { [weak self, run] in
                guard let self,
                      self.queue.sync(execute: { self.callbackGeneration == run.id }) else { return }
                if let utterance { boundary?(utterance) }
                if !consumesTrailingFinal {
                    run.onTranscript(update.displayText, false)
                }
            }
            if run.finishing, run.forceSent, run.finalObservedAfterFinish { scheduleGrace(run) }
        case "Termination": complete(run, closeCode: .normalClosure)
        default: break
        }
    }

    func handleBegin(_ run: Run) {
        guard !run.begun else { return }
        run.begun = true
        run.outbound.append(contentsOf: run.preBeginFrames.map(Outbound.audio))
        run.outboundAudioBytes = run.preBeginBytes
        run.preBeginFrames.removeAll(keepingCapacity: false)
        run.preBeginBytes = 0
        pump(run)
    }

    func fail(_ run: Run, description: String) {
        fail(run, error: NSError(
            domain: "AssemblyAI", code: -1,
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
        let transcript = run.assembler.confirmedWithLatestInterim
        let result = transcript.isEmpty ? nil : transcript
        let waiters = run.finishWaiters
        run.finishWaiters.removeAll()
        if self.run === run {
            lastAssembler = run.assembler
            self.run = nil
        }
        callbackQueue.async {
            waiters.forEach { $0.resume(returning: result) }
        }
    }
}

struct AssemblyAIPCMFramer {
    private let frameBytes: Int
    private let minimumBytes: Int
    private var buffered = Data()
    var bufferedByteCount: Int { buffered.count }

    init(sampleRate: Int) {
        frameBytes = max(2, sampleRate * 2 / 10)
        minimumBytes = max(2, sampleRate * 2 / 20)
    }

    mutating func append(_ data: Data) -> [Data] {
        buffered.append(data)
        var frames: [Data] = []
        while buffered.count >= frameBytes {
            frames.append(Data(buffered.prefix(frameBytes)))
            buffered.removeFirst(frameBytes)
        }
        return frames
    }

    mutating func finish() -> Data? {
        guard !buffered.isEmpty else { return nil }
        if buffered.count < minimumBytes {
            buffered.append(Data(repeating: 0, count: minimumBytes - buffered.count))
        }
        if !buffered.count.isMultiple(of: 2) {
            buffered.append(0)
        }
        defer { buffered.removeAll(keepingCapacity: false) }
        return buffered
    }
}

private struct AssemblyAIEnvelope: Decodable {
    let type: String?
    let turn_order: Int? // swiftlint:disable:this identifier_name
}

struct AssemblyAIStreamingTurn: Decodable {
    let turn_order: Int // swiftlint:disable:this identifier_name
    let turn_is_formatted: Bool // swiftlint:disable:this identifier_name
    let end_of_turn: Bool // swiftlint:disable:this identifier_name
    let transcript: String
    let utterance: String?
}

struct AssemblyAIStreamingTranscriptUpdate: Equatable {
    let displayText: String
    let finalizedTurn: Bool
}

struct AssemblyAIStreamingTranscriptAssembler {
    private var finalTextByTurnOrder: [Int: String] = [:]
    private var interims: [Int: String] = [:]

    private var finalTexts: [String] {
        finalTextByTurnOrder.keys.sorted().compactMap { finalTextByTurnOrder[$0] }
    }
    var confirmedText: String { finalTexts.filter { !$0.isEmpty }.joined(separator: " ") }
    var latestInterim: String {
        guard let order = interims.keys.max() else { return "" }
        return interims[order] ?? ""
    }
    var confirmedWithLatestInterim: String {
        [confirmedText, latestInterim].filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func consume(_ turn: AssemblyAIStreamingTurn) -> AssemblyAIStreamingTranscriptUpdate? {
        guard !turn.transcript.isEmpty || turn.end_of_turn else { return nil }
        let finalized = turn.end_of_turn && turn.turn_is_formatted
        if finalized {
            finalTextByTurnOrder[turn.turn_order] = turn.transcript
            interims.removeValue(forKey: turn.turn_order)
        } else {
            interims[turn.turn_order] = turn.transcript
        }
        return AssemblyAIStreamingTranscriptUpdate(
            displayText: confirmedWithLatestInterim,
            finalizedTurn: finalized
        )
    }

    func snapshot(terminal: Bool) -> StreamingTranscriptSnapshot {
        StreamingTranscriptSnapshot(
            confirmedText: confirmedText,
            pendingInterim: latestInterim,
            displayText: confirmedWithLatestInterim,
            segments: finalTexts.filter { !$0.isEmpty }.map {
                TranscriptionSegment(startTime: 0, endTime: 0, text: $0)
            },
            isTerminal: terminal
        )
    }
}
