import Foundation

/// All fields are confined to DeepgramLiveClient's serial state queue. Each
/// session owns its own counters so late sends cannot release a new run's budget.
final class DeepgramLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    var ready = false
    var outgoing: [Data] = []
    var sending = false
    var sendID: UInt64 = 0
    var closeSent = false
    let sendBudget: StreamingAudioSendBudget
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        self.sendBudget = StreamingAudioSendBudget(
            sampleRate: sampleRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }
}
