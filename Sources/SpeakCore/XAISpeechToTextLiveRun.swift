import Foundation

/// One `wss://api.x.ai/v1/stt` session's state. Every field is confined to
/// the client's serial state queue. The connection, sends, deadlines, waiters
/// and callbacks belong to this run, so a stopped or replaced run cannot be
/// mutated by a late transport callback, and a late send completion cannot
/// release a new run's budget.
final class XAISpeechToTextLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// `transcript.created` has arrived, so the service accepts audio.
    var ready = false
    /// Admitted PCM not yet handed to the transport, in capture order.
    var outgoing: [Data] = []
    var sending = false
    var sendID: UInt64 = 0
    /// `audio.done` was handed to the transport; the finish then waits for
    /// `transcript.done` rather than for the drain.
    var audioDoneSent = false
    /// `transcript.done` arrived. The server closes the socket afterwards, so
    /// only from here is a closure the normal end of the stream.
    var doneReceived = false
    let budget: StreamingAudioSendBudget
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        budget = StreamingAudioSendBudget(
            sampleRate: sampleRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }

    /// The full transcript so far, or `nil` when nothing has been finalised:
    /// the shape `finishAndWait()` returns.
    var transcript: String? { accumulated.transcriptOrNil }
}
