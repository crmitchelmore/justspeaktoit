import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Universal-3.5 Pro's shared streaming client. The transport is replaceable;
/// request construction, turn assembly, PCM framing and shutdown remain shared.
public final class AssemblyAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    let apiKey: String
    let speechModel: String
    let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let queue = DispatchQueue(label: "AssemblyAILiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    var run: AssemblyAILiveRun

    public convenience init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, session: URLSession? = nil
    ) {
        let transportSession: URLSession
        if let session { transportSession = session } else {
            let configuration = URLSessionConfiguration.default
            #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
            #endif
            configuration.timeoutIntervalForRequest = 30
            transportSession = URLSession(configuration: configuration)
        }
        self.init(apiKey: apiKey, speechModel: speechModel, sampleRate: sampleRate,
                  makeConnection: { URLSessionStreamingConnection(session: transportSession, request: $0) })
    }

    public init(
        apiKey: String, speechModel: String = AssemblyAIModels.universal35ProAPIName,
        sampleRate: Int = 16_000, makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speechModel = speechModel
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = AssemblyAILiveRun(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
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

    public func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        synchronized {
            let active = run
            guard active.phase == .connecting || active.phase == .active else { return }
            guard data.count.isMultiple(of: 2) else { fail(AssemblyAIStreamingError.invalidPCM, active); return }
            guard active.budget.admit(data.count) else { fail(stalledError, active); return }
            active.hasAudio = true
            active.outgoing.append(contentsOf: active.framer.append(data))
            pump(active)
        }
    }

    /// Preserve the established graceful stop entry point for Apple callers.
    /// Final Turn callbacks remain cumulative and continue during its short drain.
    public func stop() { synchronized { beginFinish(run, deliverCallbacks: true) } }

    /// Immediate abort for hosts that distinguish cancellation from finalisation.
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
                    beginFinish(active, deliverCallbacks: false)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    func beginFinish(_ active: AssemblyAILiveRun, deliverCallbacks: Bool) {
        guard isCurrent(active), active.attempt != nil else { close(active); return }
        if !deliverCallbacks { active.deliverWhileFinishing = false }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        active.deliverWhileFinishing = deliverCallbacks
        let held = active.framer.bufferedByteCount
        if let tail = active.framer.finish() {
            guard active.budget.admit(tail.count - held) else { fail(stalledError, active); return }
            active.outgoing.append(tail)
        }
        if !active.hasAudio { active.ending = .terminateReady }
        pump(active)
        after(8, active) { client, active in
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
}
