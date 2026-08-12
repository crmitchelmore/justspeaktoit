import Foundation

/// Checkpoints on the record-start path, in the order they must occur.
///
/// Issue #641: the audible start cue used to sound before the microphone was
/// actually capturing, so the opening syllable landed in the gap between "the
/// app says it is recording" and "the app is recording".
public enum RecordingStartStage: String, Sendable, CaseIterable {
    /// The hot key / button was handled and the session was created.
    case triggered
    /// Local audio capture is proven live (the recorder reports it is running).
    case captureReady
    /// The live-transcription audio tap is installed and the engine is running.
    /// Absent for batch/local-file sessions, which have no streaming tap.
    case streamReady
    /// The user was told recording started.
    case cuePlayed

    var diagnosticLabel: String {
        switch self {
        case .triggered: return "trigger"
        case .captureReady: return "capture-ready"
        case .streamReady: return "stream-ready"
        case .cuePlayed: return "cue"
        }
    }
}

/// Wall-clock checkpoints for one record-start attempt.
///
/// Offsets are reported in whole milliseconds from the trigger so the cold-start
/// path is observable in logs and history diagnostics rather than inferred.
public struct RecordingStartTimeline: Sendable, Equatable {
    private var timestamps: [RecordingStartStage: Date]

    public init(triggeredAt: Date) {
        self.timestamps = [.triggered: triggeredAt]
    }

    public mutating func mark(_ stage: RecordingStartStage, at date: Date) {
        self.timestamps[stage] = date
    }

    public func timestamp(of stage: RecordingStartStage) -> Date? {
        self.timestamps[stage]
    }

    /// Whole milliseconds between the trigger and `stage`; `nil` when the stage
    /// was never reached.
    public func offsetMilliseconds(of stage: RecordingStartStage) -> Int? {
        SessionLatencyMetrics.milliseconds(from: self.timestamps[.triggered], to: self.timestamps[stage])
    }

    /// The invariant this whole change exists to hold: the user is only told
    /// recording started once local capture is proven live.
    public var cueFollowedCaptureReadiness: Bool {
        guard let cue = self.timestamps[.cuePlayed] else { return true }
        guard let captureReady = self.timestamps[.captureReady] else { return false }
        return cue >= captureReady
    }

    /// Compact one-line summary for logs, e.g.
    /// `"capture-ready 82 ms, stream-ready 214 ms, cue 215 ms"`.
    public var diagnosticSummary: String {
        RecordingStartStage.allCases
            .filter { $0 != .triggered }
            .compactMap { stage in
                guard let offset = self.offsetMilliseconds(of: stage) else { return nil }
                return "\(stage.diagnosticLabel) \(SessionLatencyMetrics.formattedMilliseconds(offset))"
            }
            .joined(separator: ", ")
    }
}

/// Sequences the record-start path so the audible cue is an *effect of* proven
/// capture readiness rather than a prediction of it (issue #641).
///
/// The steps are injected because the readiness signals are platform APIs:
/// `AVAudioRecorder.isRecording` for the local file capture, and a started
/// `AVAudioEngine` with an installed input tap for live streaming modes. This
/// type owns only the ordering and the timing checkpoints — no sleeps, no
/// guessed delays.
///
/// Streaming transports (WebSocket connect, provider warm-up) deliberately do
/// **not** gate the cue: that would add hundreds of milliseconds of silence to
/// every session. Audio captured while a transport is still connecting is held
/// by ``StreamingAudioPreroll`` and replayed once it is ready, so nothing said
/// after the cue is lost.
@MainActor
public struct RecordingStartSequencer {
    public typealias Step = () async throws -> Void

    private let now: () -> Date
    private let startCapture: Step
    private let startStream: Step?
    private let playCue: () -> Void

    public init(
        now: @escaping () -> Date = Date.init,
        startCapture: @escaping Step,
        startStream: Step?,
        playCue: @escaping () -> Void
    ) {
        self.now = now
        self.startCapture = startCapture
        self.startStream = startStream
        self.playCue = playCue
    }

    /// Brings capture up and only then plays the cue. Any failure propagates
    /// with the cue unplayed — the user is never told a failed session started.
    public func run() async throws -> RecordingStartTimeline {
        var timeline = RecordingStartTimeline(triggeredAt: self.now())

        try await self.startCapture()
        timeline.mark(.captureReady, at: self.now())

        if let startStream = self.startStream {
            try await startStream()
            timeline.mark(.streamReady, at: self.now())
        }

        self.playCue()
        timeline.mark(.cuePlayed, at: self.now())
        return timeline
    }
}
