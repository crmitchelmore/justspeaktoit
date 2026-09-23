import Foundation

/// One Soniox transcription session's state. Every field is confined to the
/// client's serial state queue, so a stopped or replaced run cannot be mutated
/// by a late callback from an old socket. Each run owns its own counters and
/// budget, so a delayed send completion can never release a newer run's budget.
final class SonioxLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    /// Outbound frames in FIFO order. The configuration frame is always first,
    /// so the Soniox contract "configuration before audio" holds without a
    /// separate readiness handshake. Raw PCM stays raw in the queue; only the
    /// one frame in flight is handed to the transport.
    enum Outbound: Sendable {
        case config(String)
        case audio(Data)
        /// The empty end-of-stream frame: the server finalizes any pending
        /// tokens, emits `finished`, and closes.
        case endOfStream
    }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    var didOpen = false
    /// The configuration frame has been handed to the transport, so audio may
    /// follow it.
    var configSent = false
    /// End-of-stream was handed to the transport, including an in-flight send.
    var endOfStreamSent = false
    var deliverWhileFinishing = false

    var outgoing: [Outbound] = []
    var queuedAudioBytes = 0
    var queuedAudioFrames = 0
    var sending = false
    var sendID: UInt64 = 0
    var overflowReported = false

    let budget: StreamingAudioSendBudget

    /// The cumulative text of every `is_final` token seen this session, in
    /// arrival order. Soniox sends each final token exactly once, so this only
    /// ever grows; the non-final tail is displayed on top of it but never
    /// stored here.
    var accumulatedFinalText = ""

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        budget = StreamingAudioSendBudget(
            sampleRate: max(sampleRate, 1), seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }

    /// The whole-session transcript: the accumulated finals, trimmed, or `nil`
    /// when nothing was finalised. This is what `finishAndWait()` returns and
    /// what `close` resolves waiters with.
    var transcript: String? {
        let text = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The live display text: the finals plus the current non-final tail. Both
    /// carry their own whitespace, so they are concatenated, then trimmed.
    func display(nonFinalTail: String) -> String {
        (accumulatedFinalText + nonFinalTail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing is pending in the transport: no send is in flight and either the
    /// queue is empty or nothing in it can move before the socket opens.
    var isDrained: Bool { !sending && (outgoing.isEmpty || !didOpen) }
}
