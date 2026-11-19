import Foundation

/// Session and transport-attempt identity isolate delayed callbacks, including
/// the one permitted EU-to-global retry. All fields use the client's state queue.
final class AssemblyAILiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    /// `grace` holds Terminate for the caller's stop grace period once the
    /// trailing formatted turn arrived or its budget elapsed.
    enum Ending { case none, forceInFlight, awaitingFinal, grace, terminateReady, terminateInFlight, sent }
    final class Attempt: @unchecked Sendable {
        let connection: any StreamingWebSocketConnection
        let host: AssemblyAIStreamingEndpoint
        var didOpen = false
        var didBegin = false
        /// Spurious ENOTCONN re-arms the receive instead of failing the socket.
        var ignoredReceiveFailures = IgnoredReceiveFailureWindow()
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

    /// Audio still waits for this attempt's `Begin`, so the oldest queued
    /// frames may make room for newer ones instead of failing the run.
    var awaitingBegin: Bool { !(attempt?.didBegin ?? false) }
}

enum AssemblyAIStreamingError: LocalizedError {
    case invalidSampleRate, beginTimeout, serverFailure
    var errorDescription: String? {
        switch self {
        case .invalidSampleRate: return "The AssemblyAI audio sample rate is invalid."
        case .beginTimeout: return "AssemblyAI did not acknowledge the streaming session in time."
        case .serverFailure: return "AssemblyAI reported a streaming error. Check the selected model and credentials."
        }
    }
}
