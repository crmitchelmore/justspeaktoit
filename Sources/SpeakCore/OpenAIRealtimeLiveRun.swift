import Foundation

/// One transcription session's state. Every field is confined to the client's
/// serial state queue; sends, deadlines, waiters and callbacks belong to this
/// run, so a stopped or replaced run cannot be mutated by late callbacks.
final class OpenAIRealtimeLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    /// Raw PCM stays raw in the queue; base64/JSON exists only for the one
    /// frame in flight, so the retained expansion is bounded by a single frame.
    enum Outbound: Sendable { case sessionUpdate(String), audio(Data), commit }
    enum CommitState { case none, queued, inFlight, sent }
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
    var admittedAudioBytes = 0
    var audioBytesSinceCommit = 0
    var overflowReported = false
    var deliverWhileFinishing = false
    var commitState = CommitState.none
    /// Item created by the latest commit, once `input_audio_buffer.committed` names it.
    var expectedItemKey: String?
    var completedBeforeFinish: Set<String> = []
    let budget: StreamingAudioSendBudget
    var assembler = OpenAIRealtimeTranscriptAssembler()
    var finishWaiters: [CheckedContinuation<String?, Never>] = []
    var readyWaiters: [Waiter<Bool>] = []
    var drainWaiters: [Waiter<Void>] = []
    private var nextWaiterID: UInt64 = 0
    var onTranscript: ((String, Bool) -> Void)?
    var onEvent: ((OpenAIRealtimeLiveClient.Event) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        budget = StreamingAudioSendBudget(
            sampleRate: max(sampleRate, 1), seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }

    var transcript: String? { assembler.transcriptOrNil }

    /// Nothing is pending in the transport: no send in flight and either an
    /// empty queue or a queue that cannot move until the session is ready.
    var isDrained: Bool { !sending && (outgoing.isEmpty || !ready) }

    var commitIsInTransport: Bool { commitState == .inFlight || commitState == .sent }

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
