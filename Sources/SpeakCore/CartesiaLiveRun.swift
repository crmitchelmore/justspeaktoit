import Foundation

/// One Cartesia recording's state, read and written only under the client's
/// lock. The socket, admitted audio and its budget, send and receive
/// generations, deadlines, callbacks and finish waiters all belong to the run,
/// so a stopped or replaced run cannot be changed by a late transport, timer or
/// host callback, and a late send completion cannot release a newer run's budget.
final class CartesiaLiveRun: @unchecked Sendable {
    /// `idle` exists only before the client's first `start()` and holds audio
    /// offered that early; later runs begin at `connecting`.
    enum Phase { case idle, connecting, streaming, finishing, closed }

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The transport reported the handshake, or `connected` arrived. Audio
    /// waits for this, never for a task state.
    var opened = false

    // MARK: Outbound audio

    /// Admitted PCM not yet handed to the transport, in capture order.
    var outgoing: [Data] = []
    /// Admitted PCM bytes, queued plus in flight, against `maximumBytes`.
    var admittedBytes = 0
    let maximumBytes: Int
    /// An idle-phase admission that failed; `start()` reports it at once.
    var pendingFailure: Error?
    /// Exactly one frame is with the transport at a time.
    var sending = false
    var sendGeneration: UInt64 = 0
    /// Bytes of the frame in flight; zero while it is the close command.
    var inFlightAudioBytes = 0
    /// A pump loop is handing frames to the transport; everyone else leaves
    /// the next frame to it, so a synchronous completion never recurses.
    var pumping = false
    /// `{"type":"close"}` was handed to the transport, and later completed.
    var closeSent = false
    var closeDelivered = false
    /// The server closed while the close command was still in flight.
    var peerClosed = false

    // MARK: Inbound events

    var receiveGeneration: UInt64 = 0
    /// The receive loop is inside `connection.receive`; a completion delivered
    /// synchronously is handed back to the loop instead of recursing.
    var receiveArming = false
    var synchronousReceive: Result<StreamingWebSocketMessage, Error>?
    /// The latest words of a turn that has not ended, or nil when no such turn
    /// has produced words. Cartesia never revises emitted text, so these words
    /// are real speech that only `turn.end` would confirm.
    var openTurnDraft: String?
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    /// Deliveries held back while a finish runs. A healthy finish returns them
    /// in its whole transcript; a failed one releases them before its error,
    /// so the host's visible draft keeps every word the server emitted.
    var withheldFinals: [String] = []
    var withheldDraft: String?

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sampleRate: Int) {
        maximumBytes = max(Int(Double(max(sampleRate, 1) * 2) * CartesiaLiveClient.bufferedAudioSeconds), 1)
    }

    /// Frames admitted and not yet completed: the queue plus any audio in flight.
    var admittedFrames: Int { outgoing.count + (inFlightAudioBytes > 0 ? 1 : 0) }

    /// The confirmed transcript so far, or `nil` when no turn has ended with
    /// words: the shape `finishAndWait()` returns.
    var transcript: String? { accumulated.transcriptOrNil }
}

/// Work decided under the client's lock and performed after it is released:
/// transport calls, host callbacks, scheduling and continuation resumes never
/// run while the lock is held, so any of them may re-enter the client.
struct CartesiaLiveEffects {
    private var actions: [() -> Void] = []

    mutating func add(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }
}
