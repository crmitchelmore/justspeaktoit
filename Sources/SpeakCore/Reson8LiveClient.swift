import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reson8 realtime: handshake-gated PCM, segment finals and a correlated flush
/// barrier. State is serialized; transport/user callbacks never run on it.
public final class Reson8LiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public let finishFlushesBufferedAudio = true
    public var finalisationBudget: TimeInterval? { FileSpeechProvider.reson8FinishBudget }
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    let state = DispatchQueue(label: "com.speak.reson8.state")
    let effects = DispatchQueue(label: "com.speak.reson8.effects")
    var run = Reson8LiveRun()
    let apiKey: String
    let language: String?
    let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    static let maximumFrames = 256

    public convenience init(
        apiKey: String, language: String? = nil, sampleRate: Int = 16_000, session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String, language: String? = nil, sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
    }

    deinit { run.connection?.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        state.sync {
            let previous = run
            let active = Reson8LiveRun()
            if previous.phase == .idle {
                active.outgoing = previous.outgoing
                active.bufferedBytes = previous.bufferedBytes
                active.admittedBytes = previous.admittedBytes
                active.deferredError = previous.deferredError
            }
            close(previous)
            run = active
            active.phase = .connecting
            active.onTranscript = onTranscript
            active.onError = onError
            do {
                if let failure = active.deferredError { throw failure }
                guard !apiKey.isEmpty else { throw StreamingClientError.missingAPIKey(provider: "Reson8") }
                guard (8_000...48_000).contains(sampleRate) else {
                    throw FileSpeechError.service("Reson8 requires a valid PCM sample rate.")
                }
                let request = try Self.request(apiKey: apiKey, language: language, sampleRate: sampleRate)
                connect(active, request: request)
                deadline(10, active) { client, active in
                    if !active.open { client.fail(FileSpeechError.missingCompletion("Reson8 handshake"), active) }
                }
            } catch { fail(error, active) }
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        state.sync {
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming else { return }
            let error: Error?
            if !(8_000...48_000).contains(sampleRate) {
                error = FileSpeechError.service("Reson8 requires a valid PCM sample rate.")
            } else if !audioData.count.isMultiple(of: 2) {
                error = FileSpeechError.service("Reson8 requires aligned PCM16 audio.")
            } else if active.outgoing.count + (active.inFlight == nil ? 0 : 1) >= Self.maximumFrames
                || audioData.count > max(sampleRate, 1) * 2 * 5 - active.bufferedBytes {
                error = StreamingClientError.transportStalled(provider: "Reson8")
            } else { error = nil }
            if let error {
                if active.phase == .idle {
                    active.deferredError = error
                    active.outgoing.removeAll()
                    active.bufferedBytes = 0
                } else { fail(error, active) }
                return
            }
            guard active.deferredError == nil else { return }
            active.outgoing.append(.binary(audioData))
            active.bufferedBytes += audioData.count
            active.admittedBytes += audioData.count
            pump(active)
        }
    }

    public func stop() { state.sync { close(run) } }
    public func cancel() { stop() }

    public func finishAndWait() async -> String? {
        let active = state.sync { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled = Task.isCancelled
                state.async {
                    active.waiters.append(continuation)
                    guard active === self.run, active.phase != .closed, !cancelled else {
                        if active === self.run { self.close(active) }
                        self.answer(active)
                        return
                    }
                    guard active.phase != .finishing else { return }
                    guard active.admittedBytes > 0 else { self.close(active); return }
                    active.phase = .finishing
                    active.flushID = UUID().uuidString
                    active.outgoing.append(.text("{\"type\":\"flush_request\",\"id\":\"\(active.flushID!)\"}"))
                    self.pump(active)
                    self.deadline(FileSpeechProvider.reson8FinishBudget, active) { client, active in
                        client.fail(FileSpeechError.missingCompletion("Reson8 flush"), active)
                    }
                }
            }
        } onCancel: {
            self.state.async { if active === self.run { self.close(active) } }
        }
    }

    public func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        state.sync {
            StreamingTranscriptSnapshot(
                confirmedText: run.confirmed, pendingInterim: run.interim,
                displayText: run.display, segments: run.finals.map(\.segment),
                duration: captureDuration, isTerminal: run.phase == .closed
            )
        }
    }

    static func request(apiKey: String, language: String?, sampleRate: Int) throws -> URLRequest {
        var components = URLComponents(string: "wss://api.reson8.dev/v1/speech-to-text/realtime")!
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "include_interim", value: "true"),
            URLQueryItem(name: "include_timestamps", value: "true")
        ]
        if let code = try FileSpeechProvider.reson8Language(language) {
            components.queryItems?.append(URLQueryItem(name: "language", value: code))
        }
        guard let url = components.url else { throw StreamingClientError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func isCurrent(_ active: Reson8LiveRun) -> Bool { active === run && active.phase != .closed }

    func deadline(
        _ seconds: TimeInterval, _ active: Reson8LiveRun,
        action: @escaping @Sendable (Reson8LiveClient, Reson8LiveRun) -> Void
    ) {
        effects.async { [weak self, weak active] in
            self?.schedule(seconds) { [weak self, weak active] in
                guard let self, let active else { return }
                self.state.async { if self.isCurrent(active) { action(self, active) } }
            }
        }
    }

    func fail(_ error: Error, _ active: Reson8LiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        // Enqueue the error before retiring the run releases its finish waiters.
        effects.async { callback?(error) }
        close(active)
    }

    func close(_ active: Reson8LiveRun) {
        guard active.phase != .closed else { answer(active); return }
        active.phase = .closed
        active.outgoing.removeAll()
        active.bufferedBytes = 0
        active.inFlight = nil
        let connection = active.connection
        active.connection = nil
        effects.async { connection?.cancel() }
        answer(active)
    }

    func answer(_ active: Reson8LiveRun) {
        let value = active.confirmed.isEmpty ? nil : active.confirmed
        let waiters = active.waiters
        active.waiters.removeAll()
        effects.async { waiters.forEach { $0.resume(returning: value) } }
    }
}

final class Reson8LiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, streaming, finishing, closed }
    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    var open = false
    var outgoing: [StreamingWebSocketMessage] = []
    var inFlight: UUID?
    var bufferedBytes = 0
    var admittedBytes = 0
    var flushID: String?
    var flushHandedOff = false
    var deferredError: Error?
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var waiters: [CheckedContinuation<String?, Never>] = []
    var finals: [(start: Double?, segment: TranscriptionSegment)] = []
    var interim = ""
    var confirmed: String { finals.map(\.segment.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var display: String { [confirmed, interim].filter { !$0.isEmpty }.joined(separator: " ") }
}
