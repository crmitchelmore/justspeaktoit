import Foundation

/// Session and transport-attempt identity isolate delayed callbacks, including
/// the one permitted EU-to-global retry. All fields use the client's state queue.
final class AssemblyAILiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    enum Ending { case none, forceInFlight, awaitingFinal, terminateReady, terminateInFlight, sent }
    final class Attempt: @unchecked Sendable {
        let connection: any StreamingWebSocketConnection
        let host: AssemblyAIStreamingEndpoint
        var didOpen = false
        var didBegin = false
        init(connection: any StreamingWebSocketConnection, host: AssemblyAIStreamingEndpoint) {
            self.connection = connection
            self.host = host
        }
    }

    var phase = Phase.idle
    var ending = Ending.none
    var attempt: Attempt?
    var attemptedFallback = false
    var hasAudio = false
    var finalAfterForce = false
    var deliverWhileFinishing = false
    var outgoing: [Data] = []
    var sending = false
    var sendID: UInt64 = 0
    var framer: AssemblyAIPCMFramer
    let budget: StreamingAudioSendBudget
    var assembler = AssemblyAIStreamingTranscriptAssembler()
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        let rate = min(max(sampleRate, 1), 192_000)
        framer = AssemblyAIPCMFramer(sampleRate: rate)
        budget = StreamingAudioSendBudget(sampleRate: rate, seconds: StreamingAudioPreroll.defaultBudgetSeconds)
    }

    var transcript: String? {
        let text = assembler.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum AssemblyAIStreamingError: LocalizedError {
    case invalidPCM, invalidSampleRate, beginTimeout, serverFailure
    var errorDescription: String? {
        switch self {
        case .invalidPCM: return "AssemblyAI requires complete 16-bit PCM samples."
        case .invalidSampleRate: return "The AssemblyAI audio sample rate is invalid."
        case .beginTimeout: return "AssemblyAI did not acknowledge the streaming session in time."
        case .serverFailure: return "AssemblyAI reported a streaming error. Check the selected model and credentials."
        }
    }
}
