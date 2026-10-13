import Foundation

/// All access is confined to the owning StreamingProviderSession's state queue.
final class StreamingProviderRun: @unchecked Sendable {
    var connection: (any StreamingWebSocketConnection)?
    var closed = false
    var didOpen = false
    var setupSent = false
    var ready = false
    var finishing = false
    var endSent = false
    var firstAudio = true
    var sending = false
    var sendID = 0
    var outgoing: [Data] = []
    var reconnects = 0
    var accumulated: TranscriptAccumulator
    var seenFinalIDs = Set<String>()
    var interim = ""
    var hasFinal = false
    var failed = false
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    let budget: StreamingAudioSendBudget

    init(_ configuration: StreamingProviderSession.Configuration) {
        accumulated = TranscriptAccumulator(shape: configuration.shape)
        budget = StreamingAudioSendBudget(
            sampleRate: configuration.sampleRate, seconds: StreamingAudioPreroll.defaultBudgetSeconds
        )
    }
}
