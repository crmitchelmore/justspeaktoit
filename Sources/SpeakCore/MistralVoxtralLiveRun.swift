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
    /// The trimmed, non-empty `transcription.done` text. Authoritative for the
    /// whole session, including revisions shorter than the folded deltas.
    var completedText: String?

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    /// The best whole-session text: the `transcription.done` text when it
    /// arrived, otherwise the folded deltas, or `nil` when nothing was heard.
    var transcript: String? {
        if let completedText { return completedText }
        let folded = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? nil : folded
    }

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

    /// Clears everything the transport held, for a closed run.
    func discardOutbound() {
        outgoing.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        bufferedBytes = 0
        sending = false
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
