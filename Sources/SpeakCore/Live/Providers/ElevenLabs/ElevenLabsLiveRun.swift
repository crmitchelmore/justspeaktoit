import Foundation

/// One ElevenLabs realtime session's state, confined to the client's serial
/// state queue. Each run owns its own counters, queue and waiters so a stopped
/// or replaced run can never be mutated by a late callback from an old socket.
final class ElevenLabsLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    /// A frame waiting for the transport: admitted PCM, or the finish's
    /// manual commit, which follows every admitted frame.
    enum Outbound {
        case audio(Data)
        case commit
    }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The `session_started` frame has arrived; audio may now be sent.
    var ready = false
    /// Frames admitted but not yet handed to the transport, in capture order.
    var outgoing: [Outbound] = []
    var sending = false
    var sendID: UInt64 = 0
    /// The finish's manual commit is queued or sent; a finish sends one.
    var commitQueued = false
    /// Pairs each `committed_transcript` with its timestamped twin.
    var finalTwins = ElevenLabsFinalTwinTracker()
    /// Consecutive spurious ENOTCONN receive failures, bounded in time.
    var ignoredReceiveFailures = IgnoredReceiveFailureWindow()
    let sendBudget: StreamingAudioSendBudget
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        let budgetRate = ElevenLabsLiveProtocol.supportedSampleRates.contains(sampleRate)
            ? sampleRate : LiveTranscriptionProviderID.elevenlabs.expectedSampleRate
        self.sendBudget = StreamingAudioSendBudget(
            sampleRate: budgetRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }

    var transcript: String? { accumulated.transcriptOrNil }
}
