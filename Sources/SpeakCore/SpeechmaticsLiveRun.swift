import Foundation

/// One Speechmatics realtime session's state. Every field is confined to the
/// client's serial state queue; sends, deadlines, waiters and callbacks belong
/// to this run, so a stopped or replaced run cannot be mutated by late callbacks.
final class SpeechmaticsLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    /// The outbound queue is drained one message at a time in capture order.
    /// `StartRecognition` needs only the open socket; `AddAudio` and
    /// `EndOfStream` wait for `RecognitionStarted`. `EndOfStream` carries no
    /// payload here because its `last_seq_no` is computed at send time, once
    /// every audio frame ahead of it has been transmitted.
    enum Outbound: Sendable {
        case startRecognition(String)
        case audio(Data)
        case endOfStream
    }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The socket handshake completed, so control frames may be sent.
    var didOpen = false
    /// `RecognitionStarted` arrived, so the service will accept `AddAudio`.
    var ready = false
    var outgoing: [Outbound] = []
    /// Capture accepted from the tap but not yet large enough to be a legal
    /// `AddAudio` frame. Its bytes are counted in `budget`, so a partial tail
    /// cannot grow the retained audio past the shared ceiling.
    var outboundBuffer = Data()
    var sending = false
    var sendID: UInt64 = 0
    /// `AddAudio` frames handed to the transport. `EndOfStream.last_seq_no`
    /// reports this, floored by the server's own `AudioAdded` acknowledgements.
    var sentAudioFrameCount = 0
    var lastAcknowledgedSeqNo = -1
    var endOfStreamSent = false

    let budget: StreamingAudioSendBudget
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    var finishWaiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        budget = StreamingAudioSendBudget(
            sampleRate: sampleRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }

    var transcript: String? { accumulated.transcriptOrNil }
}
