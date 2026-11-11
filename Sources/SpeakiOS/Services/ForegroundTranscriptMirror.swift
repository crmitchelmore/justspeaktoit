#if os(iOS)
import Foundation
import SpeakCore

/// The App Group copy of the foreground run's transcript and recording flag,
/// which the copy intents, widgets and Controls read, plus the run's start
/// time. Live partials are throttled to about one write a second; the final
/// transcript is committed once at delivery.
@MainActor
struct ForegroundTranscriptMirror {
    let sharedState: SharedTranscriptionState
    private var writes = SharedTranscriptWriteThrottle()
    private var startTime: Date?

    init(sharedState: SharedTranscriptionState) {
        self.sharedState = sharedState
    }

    var elapsedSeconds: Int {
        guard let startTime else { return 0 }
        return Int(Date().timeIntervalSince(startTime))
    }

    mutating func begin() {
        writes.reset()
        startTime = Date()
        sharedState.clear()
    }

    func markRecording() {
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime
    }

    /// Writes `text` when the throttle admits it, and says whether it did:
    /// word counting is O(n) too, so callers count only admitted partials.
    mutating func admit(_ text: String) -> Bool {
        guard writes.admit(at: Date()) else { return false }
        sharedState.updateTranscript(text)
        return true
    }

    func endRecording() {
        sharedState.clearRecordingState()
    }

    /// Clears a cancelled or failed run's transcript and recording flag.
    mutating func clear() {
        startTime = nil
        sharedState.clear()
        sharedState.clearRecordingState()
    }

    mutating func finish() {
        startTime = nil
    }
}
#endif
