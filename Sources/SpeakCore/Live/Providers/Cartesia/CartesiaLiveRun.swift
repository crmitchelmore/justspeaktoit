import Foundation

/// One Cartesia recording's state, read and written only under the client's
/// lock. The socket, admitted audio and its budget, send and receive
/// generations, deadlines, callbacks and finish waiters all belong to the run,
/// so a stopped or replaced run cannot be changed by a late transport, timer or
/// host callback, and a late send completion cannot release a newer run's budget.
final class CartesiaLiveRun: LiveSendPumpRun, LiveFinishableRun, @unchecked Sendable {
    typealias Phase = LiveRunPhase

    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    /// The transport reported the handshake, or `connected` arrived. Audio
    /// waits for this, never for a task state.
    var opened = false

    // MARK: Outbound audio

    /// Repacks capture chunks into 100 ms frames; it holds the partial frame.
    var framer: CartesiaPCMFramer
    /// Framed PCM not yet handed to the transport, in capture order. Before the
    /// socket opens this is the startup audio, which keeps the newest
    /// `maximumBytes`.
    var outgoing: [Data] = []
    /// Admitted PCM bytes, queued plus in flight, against `maximumBytes`.
    var admittedBytes = 0
    let maximumBytes: Int
    /// Exactly one frame is with the transport at a time.
    var sending = false
    var sendGeneration: UInt64 = 0
    /// Bytes of the frame in flight; zero while it is the close command.
    var inFlightAudioBytes = 0
    /// A pump loop is handing frames to the transport; everyone else leaves
    /// the next frame to it, so a synchronous completion never recurses.
    var pumping = false
    /// `{"type":"close"}` was claimed under the lock, so it is never queued twice.
    var closeClaimed = false
    /// The close command was handed to the transport (its `send` invoked, not
    /// merely claimed), and later completed. Only a closure after the handoff
    /// can answer it.
    var closeSent = false
    var closeDelivered = false
    /// How the server ended the stream while the close command was still in
    /// flight; that command's completion settles it.
    var peerClosure: Error?

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
    /// Each confirmed turn, in order: the snapshot's segments.
    var confirmedSegments: [String] = []
    /// Consecutive spurious ENOTCONN receive failures, bounded in time.
    var ignoredReceiveFailures: IgnoredReceiveFailureWindow
    /// A receive failure not yet followed by a successful read or real close.
    /// A finish deadline cannot turn this unresolved error into success.
    var pendingReceiveFailure: Error?
    /// Host callbacks, finish callers and the order a failure is published in.
    var delivery = LiveRunDelivery()

    init(sampleRate: Int, ignoredReceiveWindow: TimeInterval = IgnoredReceiveFailureWindow.defaultWindow) {
        framer = CartesiaPCMFramer(sampleRate: sampleRate)
        maximumBytes = max(Int(Double(max(sampleRate, 1) * 2) * CartesiaLiveClient.bufferedAudioSeconds), 2)
        ignoredReceiveFailures = IgnoredReceiveFailureWindow(window: ignoredReceiveWindow)
    }

    /// The whole session so far, confirmed turns and the open turn's words, or
    /// `nil` when nothing has words: the shape `finishAndWait()` returns.
    var transcript: String? {
        let whole = wholeText
        return whole.isEmpty ? nil : whole
    }

    /// The open turn's latest words, trimmed; empty when no turn is open.
    private var draft: String { openTurnDraft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// Confirmed turns, then the open turn's words.
    private var wholeText: String { [accumulated.text, draft].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Confirmed turns and the open turn's latest words, kept apart.
    var snapshot: StreamingTranscriptSnapshot {
        StreamingTranscriptSnapshot(
            confirmedText: accumulated.text,
            pendingInterim: draft,
            displayText: wholeText,
            segments: confirmedSegments.map { TranscriptionSegment(startTime: 0, endTime: 0, text: $0) },
            isTerminal: phase == .closed
        )
    }
}
