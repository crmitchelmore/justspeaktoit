import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Gemini recording's state, read and written only under the client's
/// lock. The socket, admitted audio and its budget, send and receive
/// generations, deadlines, callbacks and finish waiters all belong to the run,
/// so a stopped or replaced run cannot be changed by a late transport, timer or
/// host callback. Per-socket state is reset when a `goAway` hands the run over
/// to a new socket, and every socket's callbacks are matched by identity.
final class GeminiLiveRun: @unchecked Sendable {
    /// `idle` exists only before the client's first `start()` and holds audio
    /// offered that early; later runs begin at `connecting`.
    enum Phase { case idle, connecting, streaming, finishing, closed }

    var phase = Phase.idle
    /// The handshake request and setup frame, reused by a handover's new socket.
    var request: URLRequest?
    var setupMessage = ""

    // MARK: Current socket

    var connection: (any StreamingWebSocketConnection)?
    /// Numbers the run's sockets, so a deadline armed for one never acts on
    /// the socket that replaced it.
    var socketGeneration: UInt64 = 0
    /// The transport reported the handshake.
    var opened = false
    /// The setup frame was claimed for this socket; it is always its first frame.
    var setupClaimed = false
    /// `setupComplete` arrived: audio may flow. Audio waits for this, never
    /// for a transport state or a fixed delay.
    var ready = false
    /// `goAway` arrived: no more audio goes to this socket. Its utterance is
    /// flushed with `audioStreamEnd`, then the run continues on a new socket
    /// if it still has audio to send.
    var handingOver = false
    /// `audioStreamEnd` was claimed for this socket, so it is sent once.
    var streamEndClaimed = false
    /// It was handed to the transport (its `send` invoked, not merely claimed),
    /// and later completed. Only events after the handoff can answer it.
    var streamEndSent = false
    var streamEndDelivered = false
    /// The server ended a turn after `audioStreamEnd` was handed over.
    var turnEnded = false
    /// Handovers since audio was last delivered, so a server that keeps
    /// ending replacement sessions cannot start a reconnect storm.
    var handoversWithoutAudio = 0

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
    /// Bytes of the audio frame in flight; zero for a control frame.
    var inFlightAudioBytes = 0
    /// A pump loop is handing frames to the transport; everyone else leaves
    /// the next frame to it, so a synchronous completion never recurses.
    var pumping = false

    // MARK: Inbound events

    var receiveGeneration: UInt64 = 0
    /// The receive loop is inside `connection.receive`; a completion delivered
    /// synchronously is handed back to the loop instead of recursing.
    var receiveArming = false
    var synchronousReceive: Result<StreamingWebSocketMessage, Error>?
    /// The latest interim of an utterance the server has not finalised, or nil.
    /// Its words are real speech that only an `inputTranscription` confirms.
    var openUtterance: String?
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    /// Deliveries held back while a finish runs. A healthy finish returns them
    /// in its whole transcript; a failed one releases them before its error,
    /// so the host's visible draft keeps every word the server sent.
    var withheldFinals: [String] = []
    var withheldDraft: String?

    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: Terminal delivery

    /// Transcript callbacks decided under the lock that have not returned yet.
    /// A failure report waits for them, so the host has every word the run
    /// handed over before it learns that the run failed.
    var transcriptsInFlight = 0
    /// The failure report, held until the last in-flight transcript returns.
    var deferredFailureReport: (() -> Void)?
    /// A failure is being published outside the lock: in-flight transcripts,
    /// withheld words, then the error. Finish callers that join meanwhile wait
    /// in `lateWaiters`, so no caller can return before the error is delivered.
    var deliveringFailure = false
    var lateWaiters: [CheckedContinuation<String?, Never>] = []

    init(sampleRate: Int) {
        maximumBytes = max(Int(Double(max(sampleRate, 1) * 2) * GeminiLiveClient.bufferedAudioSeconds), 1)
    }

    /// Frames admitted and not yet completed: the queue plus any audio in flight.
    var admittedFrames: Int { outgoing.count + (inFlightAudioBytes > 0 ? 1 : 0) }

    /// The confirmed transcript so far, or `nil` when no utterance has been
    /// finalised with words: the shape `finishAndWait()` returns.
    var transcript: String? { accumulated.transcriptOrNil }

    /// Forgets the replaced socket's progress; its utterance ended with it.
    func resetSocket() {
        connection = nil
        socketGeneration += 1
        opened = false
        setupClaimed = false
        ready = false
        handingOver = false
        streamEndClaimed = false
        streamEndSent = false
        streamEndDelivered = false
        turnEnded = false
        openUtterance = nil
    }
}

/// Work decided under the client's lock and performed after it is released:
/// transport calls, host callbacks, scheduling and continuation resumes never
/// run while the lock is held, so any of them may re-enter the client.
struct GeminiLiveEffects {
    private var actions: [() -> Void] = []

    mutating func add(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }
}
