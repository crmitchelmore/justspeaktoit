import Foundation

/// One Rev AI recording's state, read and written only under the client's
/// lock. The socket, admitted audio and its budget, send and receive
/// generations, deadlines, callbacks and finish waiters all belong to the run,
/// so a stopped or replaced run cannot be changed by a late transport, timer or
/// host callback, and a late send completion cannot release a newer run's budget.
final class RevAILiveRun: LiveSendPumpRun, LiveFinishableRun, @unchecked Sendable {
    typealias Phase = LiveRunPhase

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// `connected` arrived on this run's socket. Rev AI rejects audio before
    /// it, so nothing is sent until then; the frame itself proves the handshake.
    var ready = false

    // MARK: Outbound audio

    /// Admitted PCM not yet handed to the transport, in capture order.
    var outgoing: [Data] = []
    /// Admitted PCM bytes, queued plus in flight, against `maximumBytes`.
    var admittedBytes = 0
    let maximumBytes: Int
    /// Some audio was admitted. A finish without any has nothing to transcribe.
    var admittedAudio = false
    /// An idle-phase admission that failed; `start()` reports it at once.
    var pendingFailure: Error?
    /// Exactly one frame is with the transport at a time.
    var sending = false
    var sendGeneration: UInt64 = 0
    /// Bytes of the frame in flight; zero while it is `EOS`.
    var inFlightAudioBytes = 0
    /// A pump loop is handing frames to the transport; everyone else leaves
    /// the next frame to it, so a synchronous completion never recurses.
    var pumping = false
    /// `EOS` was claimed under the lock, so it is never queued twice.
    var endOfStreamClaimed = false
    /// `EOS` was handed to the transport (its `send` invoked, not merely
    /// claimed), and later completed. Only a closure after it was delivered
    /// can answer it.
    var endOfStreamSent = false
    var endOfStreamDelivered = false
    /// How the server ended the stream while `EOS` was still in flight; that
    /// send's completion settles it.
    var peerClosure: Error?
    /// A send failed without a close status. Nothing more is sent, and the
    /// receive side's closure, which names the cause, gets a short grace.
    var sendFailure: Error?

    // MARK: Inbound events

    var receiveGeneration: UInt64 = 0
    /// The receive loop is inside `connection.receive`; a completion delivered
    /// synchronously is handed back to the loop instead of recursing.
    var receiveArming = false
    var synchronousReceive: Result<StreamingWebSocketMessage, Error>?
    /// The latest words of a segment that has no final yet, or nil when the
    /// open segment has none. Only a final confirms them.
    var openPartial: String?
    var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    /// Host callbacks, finish callers and the order a failure is published in.
    var delivery = LiveRunDelivery()

    func dropOutboundAudio() {
        outgoing.removeAll()
        admittedBytes = 0
        inFlightAudioBytes = 0
        sending = false
    }

    init(sampleRate: Int) {
        maximumBytes = max(Int(Double(max(sampleRate, 1) * 2) * RevAILiveClient.bufferedAudioSeconds), 1)
    }

    /// Frames admitted and not yet completed: the queue plus any audio in flight.
    var admittedFrames: Int { outgoing.count + (inFlightAudioBytes > 0 ? 1 : 0) }

    /// The confirmed transcript so far, or `nil` when no final has had words:
    /// the shape `finishAndWait()` returns.
    var transcript: String? { accumulated.transcriptOrNil }
}
