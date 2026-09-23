import Foundation

/// One Gladia live session's state. Every field is read and written under the
/// client's lock. The session request, socket, outbound queue and budget,
/// send and receive generations, callbacks, finish waiters and deadlines all
/// belong to the run, so a stopped or replaced run cannot be changed by a late
/// HTTP, socket or timer callback.
final class GladiaLiveRun: @unchecked Sendable {
    enum Stage { case idle, initiating, connecting, open, closed }

    /// Admitted PCM stays raw in capture order; `stop_recording` follows the
    /// last admitted chunk, so it can only leave after every chunk completed.
    enum Outbound {
        case audio(Data)
        case stopRecording
    }

    /// One send handed to the transport outside the lock.
    struct PendingSend {
        let connection: any StreamingWebSocketConnection
        let message: StreamingWebSocketMessage
        let generation: UInt64
    }

    var stage = Stage.idle
    var finishing = false
    var sessionRequest: (any GladiaLiveSessionRequest)?
    var connection: (any StreamingWebSocketConnection)?
    /// `start_session` arrived. Informational: the official SDK sends audio
    /// once the socket opens.
    var sessionStarted = false

    var outgoing: [Outbound] = []
    /// Queued and in-flight PCM, including audio held before the socket opened.
    var admittedAudioBytes = 0
    var admittedAudioChunks = 0
    var admittedAnyAudio = false
    var sending = false
    /// The send currently inside `connection.send`; a completion arriving
    /// before that call returns is parked and processed by the sender's loop.
    var sendCallActive = false
    var earlySendOutcome: Result<Void, Error>?
    var inFlightAudioBytes = 0
    var sendGeneration: UInt64 = 0
    /// `stop_recording` was handed to the socket. From then `end_session` is
    /// the authoritative answer, even ahead of the send's completion.
    var stopHandedOff = false

    var receiveGeneration: UInt64 = 0
    var receiveCallActive = false
    var earlyReceive: Result<StreamingWebSocketMessage, Error>?

    var accumulator = TranscriptAccumulator(shape: .standaloneSegments)
    /// Utterances already final; a late partial for one is not a new draft.
    var finalUtteranceIDs: Set<String> = []
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    /// `onTranscript` calls decided under the lock that have not returned.
    /// A failure's report waits for them, so an error never overtakes a
    /// transcript the run had already delivered to its host.
    var transcriptCallbacksInFlight = 0
    /// A failure's report, held until those transcript callbacks return.
    var deferredReport: (() -> Void)?
    /// A failure retired the run and its `onError` has not returned yet.
    /// Finish waiters, whether registered before or joining now, stay parked
    /// until it has, so no finish can return ahead of the error.
    var reportingFailure = false

    let maximumAudioBytes: Int

    /// Five seconds of PCM16 mono, the bound this route has always held
    /// before its socket was ready, now applied to everything admitted.
    init(sampleRate: Int) {
        maximumAudioBytes = Int(Double(max(sampleRate, 1) * 2) * StreamingAudioPreroll.defaultBudgetSeconds)
    }

    /// Confirmed finals only. A failed or cancelled run never folds its
    /// latest draft in here; hosts keep that draft visible themselves.
    var transcript: String? { accumulator.transcriptOrNil }

    var isLive: Bool { stage != .idle && stage != .closed }
}

/// Work decided under the client's lock and performed after releasing it:
/// transport calls, deadlines, callbacks and waiter resumption. Nothing a
/// callback or transport does can therefore re-enter a held lock, and effects
/// run in the order the state changed. An effect may run after its run was
/// retired (behind a slow scheduler or callback), so every effect that
/// touches a transport re-checks its run immediately beforehand.
struct GladiaLiveEffects {
    private var actions: [() -> Void] = []

    mutating func append(_ action: @escaping () -> Void) { actions.append(action) }

    func run() { for action in actions { action() } }
}
