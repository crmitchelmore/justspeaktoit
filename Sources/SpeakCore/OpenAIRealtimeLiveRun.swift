import Foundation

/// One transcription session's state. Every field is confined to the client's
/// serial state queue; sends, deadlines, waiters and callbacks belong to this
/// run, so a stopped or replaced run cannot be mutated by late callbacks.
final class OpenAIRealtimeLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    /// Raw PCM stays raw in the queue; base64/JSON exists only for the one
    /// frame in flight, so the retained expansion is bounded by a single frame.
    enum Outbound: Sendable { case sessionUpdate(String), audio(Data), commit(UInt64) }
    struct Waiter<Value> { let id: UInt64; let continuation: CheckedContinuation<Value, Never> }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    var didOpen = false
    /// Our `session.update` was handed to the transport; only then can a
    /// `session.updated` be its acknowledgement.
    var sessionUpdateSent = false
    var ready = false
    var outgoing: [Outbound] = []
    var queuedAudioBytes = 0
    var queuedAudioFrames = 0
    var sending = false
    var sendID: UInt64 = 0
    var audioBytesSinceCommit = 0
    var overflowReported = false
    var deliverWhileFinishing = false

    /// Client event identity for this run's `session.update` and commits, so
    /// server errors and `input_audio_buffer.committed` acknowledgements
    /// correlate to the exact client event instead of to "some new item".
    let eventPrefix: String
    var commitSequence: UInt64 = 0
    var lastCommitSequence: UInt64?
    /// The commit whose acknowledged item, together with every other
    /// outstanding commit item, must settle before a finish returns.
    var finalCommitSequence: UInt64?
    /// Commits handed to the transport whose acknowledgement is still pending.
    /// The server acknowledges commits in order, so the FIFO names each item.
    var commitsAwaitingAck: [UInt64] = []
    var sentCommits: Set<UInt64> = []
    var itemKeysByCommit: [UInt64: String] = [:]
    var failedItemKeys: Set<String> = []
    var failedCommits: Set<UInt64> = []
    var finalizeDeadlineScheduled = false

    let budget: StreamingAudioSendBudget
    var assembler = OpenAIRealtimeTranscriptAssembler()
    var finishWaiters: [CheckedContinuation<String?, Never>] = []
    var readyWaiters: [Waiter<Bool>] = []
    var drainWaiters: [Waiter<Void>] = []
    private var nextWaiterID: UInt64 = 0
    var onTranscript: ((String, Bool) -> Void)?
    var onEvent: ((OpenAIRealtimeLiveClient.Event) -> Void)?
    var onError: ((Error) -> Void)?

    init() {
        // Only 24 kHz PCM is ever streamed: a different requested rate is
        // rejected visibly at start, so allocation never depends on caller input.
        budget = StreamingAudioSendBudget(
            sampleRate: OpenAIRealtimeProtocol.sampleRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
        eventPrefix = "jsti-" + String(UUID().uuidString.lowercased().prefix(8))
    }

    var transcript: String? { assembler.transcriptOrNil }

    /// Nothing is pending in the transport: no send in flight and either an
    /// empty queue or a queue that cannot move until the session is ready.
    var isDrained: Bool { !sending && (outgoing.isEmpty || !ready) }

    // MARK: - Commit identity

    var sessionUpdateEventID: String { "\(eventPrefix)-session-update" }

    func eventID(forCommit sequence: UInt64) -> String { "\(eventPrefix)-commit-\(sequence)" }

    func commitSequence(forEventID eventID: String?) -> UInt64? {
        let prefix = "\(eventPrefix)-commit-"
        guard let eventID, eventID.hasPrefix(prefix) else { return nil }
        return UInt64(eventID.dropFirst(prefix.count))
    }

    var finalCommitItemKey: String? { finalCommitSequence.flatMap { itemKeysByCommit[$0] } }

    var finalCommitSent: Bool { finalCommitSequence.map { sentCommits.contains($0) } ?? false }

    /// Every commit has been acknowledged and every acknowledged item has
    /// completed or failed. Items can complete out of order, so the final
    /// commit's own completion is necessary but not sufficient.
    var finishIsSettled: Bool {
        guard finalCommitSent, let finalCommitSequence,
              finalCommitItemKey != nil || failedCommits.contains(finalCommitSequence),
              commitsAwaitingAck.isEmpty else { return false }
        return itemKeysByCommit.values.allSatisfy {
            assembler.completedItemKeys.contains($0) || failedItemKeys.contains($0)
        }
    }

    // MARK: - Padding reservation

    /// Bytes and the frame slot held for the silence that pads the current
    /// turn to the server's 100 ms minimum. Reserved when audio is admitted,
    /// so the padding frame a commit appends never exceeds the byte budget or
    /// the frame bound. A turn with no audio reserves nothing.
    static func turnReservation(bytesSinceCommit: Int) -> (bytes: Int, frames: Int) {
        guard bytesSinceCommit > 0 else { return (0, 0) }
        let shortfall = max(0, OpenAIRealtimeProtocol.minimumCommitBytes - bytesSinceCommit)
        return (shortfall, shortfall > 0 ? 1 : 0)
    }

    // MARK: - Waiters

    func addReadyWaiter(_ continuation: CheckedContinuation<Bool, Never>) -> UInt64 {
        nextWaiterID += 1
        readyWaiters.append(Waiter(id: nextWaiterID, continuation: continuation))
        return nextWaiterID
    }

    func resolveReadyWaiter(_ id: UInt64, value: Bool) {
        guard let index = readyWaiters.firstIndex(where: { $0.id == id }) else { return }
        readyWaiters.remove(at: index).continuation.resume(returning: value)
    }

    func resolveAllReadyWaiters(value: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: value) }
    }

    func addDrainWaiter(_ continuation: CheckedContinuation<Void, Never>) -> UInt64 {
        nextWaiterID += 1
        drainWaiters.append(Waiter(id: nextWaiterID, continuation: continuation))
        return nextWaiterID
    }

    func resolveDrainWaiter(_ id: UInt64) {
        guard let index = drainWaiters.firstIndex(where: { $0.id == id }) else { return }
        drainWaiters.remove(at: index).continuation.resume()
    }

    func resolveAllDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.continuation.resume() }
    }
}
