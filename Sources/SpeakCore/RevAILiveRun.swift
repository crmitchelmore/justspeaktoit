import Foundation

/// One Rev AI streaming session's state. Every field is guarded by the
/// client's state lock. The socket, outbound queue, admission accounting,
/// deadlines, transcript, waiters and callbacks belong to this run, so a late
/// callback from a stopped or replaced socket can neither publish into,
/// release admission from, nor cancel the run that replaced it.
final class RevAILiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, streaming, finishing, closed }

    /// Outbound work in wire order: PCM exactly as admitted, then the one
    /// `EOS` a finish appends behind it.
    enum Outbound {
        case audio(Data)
        case endOfStream
    }

    /// What a send completion settles. Audio carries the bytes its admission
    /// reserved, so the release matches the reservation exactly.
    enum Sent: Sendable {
        case audio(bytes: Int)
        case endOfStream
    }

    /// Fixed when the run is armed. `start()` runs own a socket, attached as
    /// soon as the injected factory returns it; the pre-start run and
    /// `beginSession` runs never do. A missing connection alone therefore
    /// never makes a started run look like the socket-free parser seam.
    let usesTransport: Bool
    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The transport completed its handshake.
    var didOpen = false
    /// Rev AI's `connected` frame arrived. It is sent once, after the upgrade.
    var connectedFrame = false

    var outgoing: [Outbound] = []
    var sending = false
    var sendID: UInt64 = 0
    /// A send loop owns the queue and picks up newly queued work before it
    /// stops, so admissions and completions never start a nested loop.
    var pumping = false
    /// The same arrangement for the one outstanding receive.
    var receiving = false
    var receiveRequested = false

    /// PCM frames and bytes admitted and not yet completed: held for
    /// `connected`, queued behind a send, or the one in flight. Both bounds
    /// cover all of them, so no admitted audio is ever evicted.
    var bufferedFrames = 0
    var bufferedBytes = 0
    /// PCM admitted this run, sent or not. A finish with none has nothing to
    /// commit, so it does not open a stream only to end it.
    var admittedAudioBytes = 0
    /// `EOS` was handed to the transport, which happens only after every
    /// admitted frame completed its send without error.
    var endOfStreamHandedOff = false
    /// The transport reported `EOS` sent.
    var endOfStreamSent = false
    /// A send failed. Nothing more is sent; the receive side, which still
    /// holds any trailing messages and the peer's close code, decides how the
    /// run ends unless its grace elapses first.
    var sendFailure: Error?

    /// Finals only, each a standalone section. Partials are the visible draft
    /// of the current section and are never folded in, so a failed or
    /// cancelled finish returns confirmed words and nothing else.
    var confirmed = TranscriptAccumulator(shape: .standaloneSegments)

    /// A chunk offered before `start()` that could not be held. With no
    /// callback yet, the refusal fails the next run as soon as it starts.
    var deferredFailure: Error?
    /// The run failed and its `onError` has not returned yet. Finishes of it,
    /// including ones that join now, wait in `waiters` until it has.
    var deliveringFailure = false

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(usesTransport: Bool) {
        self.usesTransport = usesTransport
    }

    /// The whole-session confirmed transcript, or `nil` when nothing was
    /// finalised.
    var transcript: String? { confirmed.transcriptOrNil }

    /// Audio may leave: the real handshake and `connected` have both arrived.
    /// Transports can report them in either order. A socket-free run has no
    /// handshake, so `connected` alone suffices there.
    var isReady: Bool { connectedFrame && (didOpen || !usesTransport) }

    /// A normal close now completes the session: the finish handed `EOS` to
    /// the transport behind every admitted frame, each of which completed
    /// without error. Rev AI documents that close only as its answer to `EOS`,
    /// and a transport may report the peer's close before the write
    /// completion of `EOS` itself, so the hand-off is the requirement.
    var acceptsCompletion: Bool { phase == .finishing && endOfStreamHandedOff && bufferedFrames == 0 }

    /// Queues `pcm` as one frame, or answers `false` without queuing anything
    /// when either bound would be exceeded.
    func admit(_ pcm: Data, frameLimit: Int, byteLimit: Int) -> Bool {
        guard bufferedFrames < frameLimit, bufferedBytes + pcm.count <= byteLimit else { return false }
        outgoing.append(.audio(pcm))
        bufferedFrames += 1
        bufferedBytes += pcm.count
        admittedAudioBytes += pcm.count
        return true
    }

    /// Takes the head of the queue for its send.
    func takeNext() -> Outbound {
        let item = outgoing.removeFirst()
        sending = true
        sendID &+= 1
        if case .endOfStream = item { endOfStreamHandedOff = true }
        return item
    }

    /// Moves audio held before `start()` into this run, in capture order and
    /// with the reservations it already holds, so the bounds still hold.
    func adoptHeldAudio(from idle: RevAILiveRun) {
        outgoing.append(contentsOf: idle.outgoing)
        bufferedFrames += idle.bufferedFrames
        bufferedBytes += idle.bufferedBytes
        admittedAudioBytes += idle.admittedAudioBytes
    }

    /// Audio admitted and not yet handed to the transport. Nothing is evicted,
    /// so the dropped count is always zero.
    var heldAudio: StreamingAudioPreroll.Snapshot {
        var frames = 0
        var bytes = 0
        for case .audio(let pcm) in outgoing {
            frames += 1
            bytes += pcm.count
        }
        return StreamingAudioPreroll.Snapshot(chunkCount: frames, byteCount: bytes, droppedChunkCount: 0)
    }

    /// Clears everything the transport held, for a closed or refused run.
    func discardOutbound() {
        outgoing.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        bufferedBytes = 0
        sending = false
    }

    /// Detaches the run: nothing more is sent, received or delivered for it,
    /// and its deadlines become inert. Answers `false` if it already was.
    @discardableResult
    func retire(_ effects: inout RevAILiveEffects) -> Bool {
        guard phase != .closed else { return false }
        phase = .closed
        let detached = connection
        connection = nil
        discardOutbound()
        onTranscript = nil
        onError = nil
        if let detached { effects.append { detached.cancel() } }
        return true
    }

    /// Resumes every waiting finish with the confirmed transcript.
    func releaseWaiters(_ effects: inout RevAILiveEffects) {
        let resumed = waiters
        waiters.removeAll()
        let text = transcript
        if !resumed.isEmpty { effects.append { resumed.forEach { $0.resume(returning: text) } } }
    }

    /// Answers a finish of this run once it is no longer current: at once, or,
    /// while its failure is still being delivered, only after that delivery,
    /// so a late finish can never return before the error it must follow.
    func answerRetired(_ continuation: CheckedContinuation<String?, Never>, _ effects: inout RevAILiveEffects) {
        guard !deliveringFailure else {
            waiters.append(continuation)
            return
        }
        let text = transcript
        effects.append { continuation.resume(returning: text) }
    }
}

/// Work collected while the client's state lock is held and performed, in
/// order, once it is released. Transport calls, scheduling, host callbacks and
/// waiter resumptions never run under the lock, so each may re-enter the
/// client, including by starting a replacement session.
struct RevAILiveEffects {
    private var actions: [() -> Void] = []

    mutating func append(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }
}
