import Foundation
import SpeakCore

/// One recording's shared live state. Hosts poll the latest snapshot, persist
/// audio themselves and pass PCM synchronously; there is no second audio queue
/// or per-frame task here. Every session is one-shot and has its own identity.
public final class DesktopLiveSession: @unchecked Sendable {
    public enum Phase: String, Sendable {
        case idle, recording, finishing, finished, cancelled, failed
    }

    public struct Snapshot: Equatable, Sendable {
        public let id: UUID
        public let revision: UInt64
        public let text: String
        public let error: String?
        public let phase: Phase
    }

    public let id: UUID
    public let keywordLimitation: String?
    private let client: any FinalizingStreamingTranscriptionClient
    /// Lifecycle/audio calls cannot overtake each other. Provider callbacks
    /// read provider projections before acquiring stateLock, so synchronous
    /// callbacks cannot form a lock cycle with a provider's own serial queue.
    private let calls = NSLock()
    private let stateLock = NSLock()
    private var phase = Phase.idle
    private var revision: UInt64 = 0
    private var accumulator: TranscriptAccumulator
    private var text = ""
    private var error: String?
    private var firstTranscript: ContinuousClock.Instant?
    public var firstTranscriptAt: ContinuousClock.Instant? { stateLock.withLock { firstTranscript } }
    private var finishingTask: Task<Snapshot, Never>?
    /// Confined to calls. Clients may also close themselves during finalisation.
    private var stopped = false

    public init(
        client: any FinalizingStreamingTranscriptionClient, id: UUID = UUID(), keywordLimitation: String? = nil
    ) {
        self.client = client
        self.id = id
        self.keywordLimitation = keywordLimitation
        self.accumulator = TranscriptAccumulator(shape: client.finalShape)
    }

    deinit { if !stopped { client.cancel() } }

    public func snapshot() -> Snapshot { stateLock.withLock { currentSnapshot() } }

    public func start() {
        calls.withLock {
            let shouldStart = stateLock.withLock {
                guard phase == .idle else { return false }
                phase = .recording
                revision += 1
                return true
            }
            guard shouldStart else { return }
            client.start(
                onTranscript: { [weak self] text, final in self?.receive(text, isFinal: final) },
                onError: { [weak self] error in self?.fail(error) }
            )
            if stateLock.withLock({ phase == .failed }) { stopClient() }
        }
    }

    public func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        calls.withLock {
            guard stateLock.withLock({ phase == .recording }) else { return }
            client.sendAudio(data)
            if stateLock.withLock({ phase == .failed }) { stopClient() }
        }
    }

    /// Exactly one provider finish runs, even when multiple callers await it.
    /// The provider returns a whole-session transcript, which replaces display
    /// text unless a provider supplies an authoritative final projection.
    /// Unprojected nil/blank success is empty. Errors and cancellation retain
    /// the best display text instead of inventing a completed result.
    public func finish() async -> Snapshot {
        if Task.isCancelled { return cancel() }
        let task = beginFinish()
        guard let task else { return snapshot() }
        return await withTaskCancellationHandler {
            if Task.isCancelled { _ = cancel() }
            return await task.value
        } onCancel: { _ = self.cancel() }
    }

    @discardableResult
    public func cancel() -> Snapshot {
        calls.withLock {
            let task = stateLock.withLock {
                if phase == .idle || phase == .recording || phase == .finishing {
                    phase = .cancelled
                    revision += 1
                }
                return finishingTask
            }
            task?.cancel()
            stopClient()
            return snapshot()
        }
    }

    private func beginFinish() -> Task<Snapshot, Never>? {
        calls.withLock {
            let task: Task<Snapshot, Never>? = stateLock.withLock {
                if phase == .finishing { return finishingTask }
                guard phase == .recording else {
                    if phase == .idle { phase = .finished; revision += 1 }
                    return nil
                }
                phase = .finishing
                revision += 1
                let task = Task { await self.completeFinish() }
                finishingTask = task
                return task
            }
            if task == nil { stopClient() }
            return task
        }
    }

    private func completeFinish() async -> Snapshot {
        guard stateLock.withLock({ phase == .finishing }) else { return snapshot() }
        let final = await client.finishAndWait()
        let projection = (client as? StreamingTranscriptSnapshotProviding)?
            .transcriptSnapshot(captureDuration: 0)
        return calls.withLock {
            stateLock.withLock {
                if phase == .finishing {
                    accumulator.replace(with: final ?? "")
                    text = accumulator.text
                    if let projection, let resolved = projection.resolvedDisplayText,
                       projection.confirmedText != nil ||
                       !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = SharedTranscriptProjection.apply(
                            eventText: final ?? "", isFinal: true, snapshot: projection, accumulator: &accumulator
                        ) ?? accumulator.text
                    }
                    phase = .finished
                    revision += 1
                }
            }
            stopClient()
            return snapshot()
        }
    }

    private func receive(_ transcript: String, isFinal: Bool) {
        let projection = (client as? StreamingTranscriptSnapshotProviding)?
            .transcriptSnapshot(captureDuration: 0)
        stateLock.withLock {
            guard phase == .recording || phase == .finishing else { return }
            if firstTranscript == nil, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstTranscript = .now
            }
            let next: String
            if projection?.resolvedDisplayText != nil {
                next = SharedTranscriptProjection.apply(
                    eventText: transcript, isFinal: isFinal, snapshot: projection, accumulator: &accumulator
                ) ?? accumulator.text
            } else if isFinal {
                next = accumulator.append(final: transcript)
            } else { next = accumulator.display(withInterim: transcript) }
            if next != text { text = next; revision += 1 }
        }
    }

    private func fail(_ failure: Error) {
        let message = failure.localizedDescription
        stateLock.withLock {
            guard phase == .recording || phase == .finishing else { return }
            error = message
            phase = .failed
            revision += 1
        }
    }

    /// Called only under calls, never under stateLock. Callbacks can re-enter
    /// the state lock and will see a terminal phase before stop is invoked.
    private func stopClient() {
        guard !stopped else { return }
        stopped = true
        client.cancel()
    }

    /// Caller must hold stateLock.
    private func currentSnapshot() -> Snapshot {
        Snapshot(id: id, revision: revision, text: text, error: error, phase: phase)
    }
}
