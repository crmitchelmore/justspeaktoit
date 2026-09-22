import Foundation

/// One ElevenLabs realtime session's state, confined to the client's serial
/// state queue. Each run owns its own counters, queue and waiters so a stopped
/// or replaced run can never be mutated by a late callback from an old socket.
final class ElevenLabsLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The `session_started` frame has arrived; audio may now be sent.
    var ready = false
    /// PCM frames admitted but not yet handed to the transport.
    var outgoing: [Data] = []
    var sending = false
    var sendID: UInt64 = 0
    /// Bytes handed to the transport for the current manual segment, including
    /// an in-flight chunk. No segment may cross the client-owned time boundary.
    var segmentBytes = 0
    var commitSequence: UInt64 = 0
    var pendingCommit: UInt64?
    /// A response can precede its send completion; both must succeed before
    /// another segment is sent or graceful finish is acknowledged.
    var commitFinalReceived = false
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
