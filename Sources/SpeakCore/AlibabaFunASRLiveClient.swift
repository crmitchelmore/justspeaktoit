import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared Fun-ASR duplex protocol. All state belongs to an identity-isolated run
/// confined to the serial queue, including in-flight send completions.
public final class AlibabaFunASRLiveClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public let finishFlushesBufferedAudio = true
    public var finalisationBudget: TimeInterval? { 5 }
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let credentials: String
    private let makeConnection: ConnectionFactory
    private let schedule: Scheduler
    private let queue = DispatchQueue(label: "AlibabaFunASRLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var run = AlibabaFunASRLiveRun()
    private static let maximumBytes = 16_000 * 2 * 5
    private static let maximumFrames = 256
    static let maximumResponseBytes = 1_024 * 1_024

    public convenience init(credentials: String, session: URLSession = .shared) {
        self.init(credentials: credentials, makeConnection: {
            URLSessionStreamingConnection(session: session, request: $0)
        })
    }

    public init(
        credentials: String, makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.credentials = credentials
        self.makeConnection = makeConnection
        self.schedule = schedule
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            let held = run.phase == .idle ? run.outgoing : []
            let overflowed = run.phase == .idle && run.overflowed
            close(run)
            let active = AlibabaFunASRLiveRun()
            run = active
            active.outgoing = held
            active.queuedBytes = held.reduce(0) { $0 + $1.count }
            active.onTranscript = onTranscript
            active.onError = onError
            active.phase = .connecting
            do {
                guard !overflowed else { throw stalledError }
                let config = try AlibabaSpeechConfiguration(credentials: credentials)
                try config.validateModel(AlibabaSpeechModels.funLive)
                var request = URLRequest(url: config.liveURL)
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                let connection = makeConnection(request)
                active.connection = connection
                connection.resume { [weak self, weak active] in
                    guard let self, let active else { return }
                    self.synchronized {
                        guard self.isCurrent(active), !active.opened else { return }
                        active.opened = true
                        do {
                            self.send(.text(try Self.control("run-task", active)), bytes: 0, active)
                        } catch { self.fail(error, active) }
                    }
                }
                receive(active, connection)
                after(10, active) { client, active in
                    if !active.ready { client.fail(AlibabaSpeechError.sessionNotReady, active) }
                }
            } catch { fail(error, active) }
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .active else { return }
            guard audioData.count % 2 == 0 else {
                if active.phase == .idle {
                    active.overflowed = true
                } else { fail(AlibabaSpeechError.unsupportedFormat, active) }
                return
            }
            guard active.outgoing.count + (active.sending ? 1 : 0) < Self.maximumFrames,
                  audioData.count <= Self.maximumBytes - active.queuedBytes else {
                if active.phase == .idle { active.overflowed = true } else { fail(stalledError, active) }
                return
            }
            active.queuedBytes += audioData.count
            active.outgoing.append(audioData)
            pump(active)
        }
    }

    public func stop() { synchronized { close(run) } }
    public func cancel() { stop() }

    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), active.connection != nil, !Task.isCancelled else {
                        if active === run { close(active) }
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    active.waiters.append(continuation)
                    guard active.phase != .finishing else { return }
                    active.phase = .finishing
                    pump(active)
                    after(5, active) { client, active in
                        client.fail(active.ready ? AlibabaSpeechError.missingCompletion
                                    : AlibabaSpeechError.sessionNotReady, active)
                    }
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    public func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        synchronized {
            StreamingTranscriptSnapshot(
                confirmedText: run.confirmed, pendingInterim: run.interim, displayText: run.display,
                segments: run.orderedSentences.filter(\.final).compactMap { sentence in
                    guard let end = sentence.end else { return nil }
                    return TranscriptionSegment(startTime: sentence.start, endTime: end, text: sentence.text)
                },
                duration: captureDuration, isTerminal: run.phase == .closed
            )
        }
    }

    private func pump(_ active: AlibabaFunASRLiveRun) {
        guard isCurrent(active), active.ready, !active.sending else { return }
        if !active.outgoing.isEmpty {
            let data = active.outgoing.removeFirst()
            send(.binary(data), bytes: data.count, active)
        } else if active.phase == .finishing, !active.finishSent {
            active.finishSent = true
            do {
                send(.text(try Self.control("finish-task", active)), bytes: 0, active)
            } catch { fail(error, active) }
        }
    }

    private func send(_ message: StreamingWebSocketMessage, bytes: Int, _ active: AlibabaFunASRLiveRun) {
        guard isCurrent(active), let connection = active.connection else { return }
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), active.sending, active.sendID == sendID else { return }
                active.sending = false
                active.queuedBytes -= bytes
                if let error { self.fail(error, active) } else { self.pump(active) }
            }
        }
        after(5, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func receive(_ active: AlibabaFunASRLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error): self.fail(error, active)
                case .success(let message):
                    do {
                        let data: Data
                        switch message {
                        case .text(let text):
                            guard text.utf8.count <= Self.maximumResponseBytes else {
                                throw AlibabaSpeechError.invalidResponse
                            }
                            data = Data(text.utf8)
                        case .binary(let binary):
                            guard binary.count <= Self.maximumResponseBytes else {
                                throw AlibabaSpeechError.invalidResponse
                            }
                            data = binary
                        }
                        try self.handle(data, active)
                        self.receive(active, connection)
                    } catch { self.fail(error, active) }
                }
            }
        }
    }

}

extension AlibabaFunASRLiveClient {
    private func handle(_ data: Data, _ active: AlibabaFunASRLiveRun) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any], let event = header["event"] as? String else {
            throw AlibabaSpeechError.invalidResponse
        }
        guard header["task_id"] as? String == active.taskID else { return }
        switch event {
        case "task-started":
            guard !active.ready else { return }
            active.ready = true
            if active.phase == .connecting { active.phase = .active }
            pump(active)
        case "task-failed":
            throw AlibabaSpeechError.providerFailure(header["error_code"] as? String ?? "task-failed")
        case "task-finished":
            guard active.phase == .finishing, active.finishSent, active.interim.isEmpty else {
                throw AlibabaSpeechError.missingCompletion
            }
            close(active)
        case "result-generated":
            try recordSentence(object, active)
        default: break
        }
    }

    private func recordSentence(_ object: [String: Any], _ active: AlibabaFunASRLiveRun) throws {
        guard active.ready, let payload = object["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any],
              let text = sentence["text"] as? String,
              let final = sentence["sentence_end"] as? Bool,
              let begin = sentence["begin_time"] as? Double,
              begin.isFinite, begin >= 0,
              let identifier = sentence["sentence_id"] as? Int ?? sentence["begin_time"] as? Int else {
            throw AlibabaSpeechError.invalidResponse
        }
        // A final sentence can be corrected or restated, but never reopened
        // by a late partial. Repeated words with distinct identities survive.
        if active.sentences[identifier]?.final == true, !final { return }
        let end = sentence["end_time"] as? Double
        active.sentences[identifier] = .init(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), final: final,
            start: begin / 1_000, end: end.flatMap { $0.isFinite && $0 >= begin ? $0 / 1_000 : nil }
        )
        if active.phase != .finishing { active.onTranscript?(final ? active.confirmed : active.display, final) }
    }

    private static func control(_ action: String, _ active: AlibabaFunASRLiveRun) throws -> String {
        var payload: [String: Any] = ["input": [String: String]()]
        if action == "run-task" {
            payload.merge([
                "task_group": "audio", "task": "asr", "function": "recognition", "model": "fun-asr-realtime",
                "parameters": ["format": "pcm", "sample_rate": 16_000]
            ]) { _, new in new }
        }
        guard let text = String(data: try JSONSerialization.data(withJSONObject: [
            "header": ["action": action, "task_id": active.taskID, "streaming": "duplex"], "payload": payload
        ]), encoding: .utf8) else { throw AlibabaSpeechError.invalidResponse }
        return text
    }

    private var stalledError: Error { StreamingClientError.transportStalled(provider: "Alibaba") }
    private func isCurrent(_ active: AlibabaFunASRLiveRun) -> Bool { active === run && active.phase != .closed }

    private func fail(_ error: Error, _ active: AlibabaFunASRLiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        close(active)
        // Hosts must receive the error before recovered text is returned.
        callback?(error)
        waiters.forEach { $0.resume(returning: active.transcript) }
    }

    private func close(_ active: AlibabaFunASRLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.queuedBytes = 0
        active.sending = false
        let waiters = active.waiters
        active.waiters.removeAll()
        active.onTranscript = nil
        active.onError = nil
        connection?.cancel()
        waiters.forEach { $0.resume(returning: active.transcript) }
    }

    private func after(
        _ seconds: TimeInterval, _ active: AlibabaFunASRLiveRun,
        action: @escaping @Sendable (AlibabaFunASRLiveClient, AlibabaFunASRLiveRun) -> Void
    ) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    private func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }
}
