import Foundation

/// One Voxtral Realtime session's state. Every field is guarded by the
/// client's state lock. The connection, outbound queue, accounting, deadlines,
/// waiters and callbacks belong to this run, so a late callback from a stopped
/// or replaced socket can neither publish into, release budget from, nor
/// cancel the run that replaced it.
final class MistralVoxtralLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, streaming, finishing, closed }

    /// Outbound work in wire order. PCM stays raw until its own send, so only
    /// the one frame in flight is ever base64 encoded.
    enum Outbound {
        case sessionUpdate
        case audio(Data)
        case flush
        case end
    }

    /// What a send completion settles. Audio carries the encoded bytes its
    /// admission reserved, so the release matches the reservation exactly.
    enum Sent: Sendable {
        case sessionUpdate
        case audio(bytes: Int)
        case flush
        case end

        init(_ item: Outbound) {
            switch item {
            case .sessionUpdate: self = .sessionUpdate
            case .audio(let pcm):
                self = .audio(bytes: MistralVoxtralLiveClient.appendFrameByteCount(pcmBytes: pcm.count))
            case .flush: self = .flush
            case .end: self = .end
            }
        }
    }

    var phase = Phase.idle
    /// Set by `start()`: the run owns a socket, attached as soon as the
    /// injected factory returns it. `beginSession` runs are the socket-free
    /// parser seam, so a missing connection alone never means "no transport".
    var usesTransport = false
    var connection: (any StreamingWebSocketConnection)?
    /// The transport finished its handshake.
    var didOpen = false
    /// `session.created` arrived, so the session exists and may be configured.
    var sessionCreated = false
    /// `session.update` completed its send, so audio may follow. The SDK awaits
    /// that send; it does not wait for a `session.updated` acknowledgement.
    var configured = false

    var outgoing: [Outbound] = []
    var sending = false
    var sendID: UInt64 = 0
    /// A send loop owns this run's queue and picks up newly queued work before
    /// it stops, so completions and admissions never start a nested loop.
    var pumping = false
    /// The same arrangement for the one outstanding receive.
    var receiving = false
    var receiveRequested = false

    /// `input_audio.append` frames queued or in flight, and the encoded bytes
    /// reserved for them. Audio held before readiness counts against the same
    /// bounds as audio waiting behind a slow send.
    var bufferedFrames = 0
    var bufferedBytes = 0
    /// PCM admitted this run, sent or not. A finish with none has nothing to
    /// flush.
    var admittedAudioBytes = 0

    /// Handed to the transport, which may deliver `transcription.done` before
    /// it completes the send.
    var flushHandedOff = false
    var endHandedOff = false

    /// Append-only `transcription.text.delta` fragments, folded in order.
    var streamedText = ""
    /// The trimmed, non-empty text of the `transcription.done` that completed
    /// the session. Authoritative, including revisions shorter than the deltas.
    var completedText: String?
    /// The text of a `transcription.done` that arrived too early to complete
    /// the session. Never authoritative: it is recovery text only when no
    /// draft was ever visible.
    var unconfirmedText: String?
    /// A chunk offered before `start()` that could not be held. With no
    /// callback yet, the refusal fails the next run as soon as it starts.
    var deferredFailure: Error?
    /// The run failed and its `onError` has not returned yet. Finishes of it,
    /// including ones that join now, wait in `waiters` until it has.
    var deliveringFailure = false

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    /// The best whole-session text, by provenance rather than by comparing
    /// texts: the done that completed the session; otherwise the visible
    /// folded draft; otherwise an early done's text, the only text heard.
    /// `nil` when nothing was heard. Only the first is ever a success.
    var transcript: String? {
        if let completedText { return completedText }
        let folded = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? unconfirmedText : folded
    }

    /// Whether a `transcription.done` now completes the session. The flush is
    /// handed off only when every admitted append has completed its send
    /// without error (one frame in flight, in order; a failed send ends the
    /// run), so from then on the service has all of the recording.
    var acceptsCompletion: Bool { phase == .finishing && flushHandedOff && bufferedFrames == 0 }

    /// Whether the head of the queue may leave now. Configuration needs the
    /// real handshake and `session.created`; everything after it needs the
    /// configuration to have been sent.
    func canSend(_ item: Outbound) -> Bool {
        switch item {
        case .sessionUpdate: return didOpen && sessionCreated
        case .audio, .flush, .end: return configured
        }
    }

    /// Queues `pcm` as append frames split at the decoded cap, or answers
    /// `false` without queuing anything when either bound would be exceeded.
    /// The cost is computed from the length alone, so an oversized chunk is
    /// refused before any of it is sliced or encoded.
    func admit(_ pcm: Data, frameLimit: Int, byteLimit: Int) -> Bool {
        let cost = MistralVoxtralLiveClient.appendCost(pcmBytes: pcm.count)
        guard bufferedFrames + cost.frames <= frameLimit, bufferedBytes + cost.bytes <= byteLimit else { return false }
        for slice in MistralVoxtralLiveClient.appendSlices(of: pcm) { outgoing.append(.audio(slice)) }
        bufferedFrames += cost.frames
        bufferedBytes += cost.bytes
        admittedAudioBytes += pcm.count
        return true
    }

    /// Takes the head of the queue for its send, marking control frames as
    /// handed off. The caller has checked `canSend`.
    func takeNext() -> Outbound {
        let item = outgoing.removeFirst()
        sending = true
        sendID &+= 1
        if case .flush = item { flushHandedOff = true }
        if case .end = item { endHandedOff = true }
        return item
    }

    /// Moves audio held before `start()` into this run, behind its
    /// configuration and with the reservations it already holds. The idle run
    /// admitted it against the same bounds, so the bounds still hold.
    func adoptHeldAudio(from idle: MistralVoxtralLiveRun) {
        outgoing.append(contentsOf: idle.outgoing)
        bufferedFrames += idle.bufferedFrames
        bufferedBytes += idle.bufferedBytes
        admittedAudioBytes += idle.admittedAudioBytes
    }

    /// Clears everything the transport held, for a closed run.
    func discardOutbound() {
        outgoing.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        bufferedBytes = 0
        sending = false
    }

    /// Detaches the run: nothing more is sent, received or delivered for it,
    /// and its deadlines become inert. Answers `false` if it already was.
    @discardableResult
    func retire(_ effects: inout MistralVoxtralLiveEffects) -> Bool {
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

    /// Resumes every waiting finish with the run's text.
    func releaseWaiters(_ effects: inout MistralVoxtralLiveEffects) {
        let resumed = waiters
        waiters.removeAll()
        let text = transcript
        if !resumed.isEmpty { effects.append { resumed.forEach { $0.resume(returning: text) } } }
    }

    /// Answers a finish of this run once it is no longer current: with its
    /// text at once, or, while its failure is still being delivered, only
    /// after that delivery, so a late finish cannot return before the error.
    func answerRetired(
        _ continuation: CheckedContinuation<String?, Never>, _ effects: inout MistralVoxtralLiveEffects
    ) {
        guard !deliveringFailure else {
            waiters.append(continuation)
            return
        }
        let text = transcript
        effects.append { continuation.resume(returning: text) }
    }
}

/// Work collected while the client's state lock is held and performed, in
/// order, once it is released. Transport calls, scheduling, callbacks and
/// waiter resumptions never run under the lock, so each may re-enter the
/// client, including by starting a replacement session.
struct MistralVoxtralLiveEffects {
    private var actions: [() -> Void] = []

    mutating func append(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }
}
