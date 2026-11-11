#if os(iOS)
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "iOSLiveTranscriber")

/// Folds legacy `SFSpeechRecognizer` updates into one session transcript.
///
/// The legacy recogniser restarts after every mid-session `isFinal` and can
/// silently reset its `formattedString` after a pause. This value keeps the
/// text committed by earlier tasks, detects those implicit resets, and keeps
/// the segments of every finished task for the final result.
struct LegacyAppleTranscriptAssembly {
    private(set) var latestResult: LegacyAppleRecognitionUpdate?
    private var accumulatedSegments: [TranscriptionSegment] = []
    /// Accumulated text from recognition segments finalised mid-session (on pause).
    private var committedText = ""
    /// Last `formattedString` received from the recognizer, used to detect
    /// implicit text resets where Apple silently clears the transcript.
    private var lastFormattedString = ""

    /// Folds `result` and returns the full display text, or nil when an empty
    /// terminal payload must not erase a usable preceding partial.
    mutating func receive(_ result: LegacyAppleRecognitionUpdate, terminal: Bool) -> String? {
        guard !terminal || !result.text.isEmpty || lastFormattedString.isEmpty else { return nil }
        commitIfImplicitReset(currentText: result.text, isFinal: result.isFinal)
        latestResult = result
        lastFormattedString = result.text
        let text = [committedText, result.text].filter { !$0.isEmpty }.joined(separator: " ")
        if result.isFinal {
            committedText = text
            lastFormattedString = ""
        }
        return text
    }

    /// Keeps the finished task's segments before its replacement starts.
    mutating func keepLatestSegments() {
        guard let latestResult else { return }
        accumulatedSegments.append(contentsOf: latestResult.segments)
    }

    /// Clears the per-task view once the finished task has been cancelled.
    mutating func beginNextTask() {
        latestResult = nil
        lastFormattedString = ""
    }

    /// Every finished task's segments, then the current task's, with their
    /// mean confidence (or `fallbackConfidence` when none carries one).
    func finalSegments(fallbackConfidence: Double?) -> ([TranscriptionSegment], Double?) {
        let segments = accumulatedSegments + (latestResult?.segments ?? [])
        let confidences = segments.compactMap(\.confidence)
        guard !confidences.isEmpty else { return (segments, fallbackConfidence) }
        return (segments, confidences.reduce(0, +) / Double(confidences.count))
    }

    /// Detect when Apple's recognizer silently resets `formattedString` after
    /// a pause without sending `isFinal`.  If the new text is dramatically
    /// shorter than the previous result, commit the old text to prevent loss.
    private mutating func commitIfImplicitReset(currentText: String, isFinal: Bool) {
        guard !isFinal,
              lastFormattedString.count >= 1,
              currentText.count < lastFormattedString.count / 2
        else { return }
        let resetLength = lastFormattedString.count
        logger.info("Implicit text reset – committing \(resetLength) chars")
        committedText = [committedText, lastFormattedString]
            .filter { !$0.isEmpty }.joined(separator: " ")
        keepLatestSegments()
    }
}
#endif
