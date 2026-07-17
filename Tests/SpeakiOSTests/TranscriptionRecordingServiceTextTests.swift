#if os(iOS)
import XCTest

@testable import SpeakiOSLib

/// Covers the stop-time transcript selection that keeps the clipboard, history
/// entry, and spoken "Copied N words" dialog consistent — the fix for short
/// background recordings landing an empty clipboard.
@MainActor
final class TranscriptionRecordingServiceTextTests: XCTestCase {

    func testPolishingPlaceholderDoesNotExposePreviousClipboardContent() {
        XCTAssertEqual(
            TranscriptionRecordingService.polishingClipboardPlaceholder,
            "Polishing… please wait"
        )
    }

    func testPrefersTranscriberResultWhenPresent() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["final result", "interim", "older"],
            fallback: ""
        )
        XCTAssertEqual(text, "final result")
    }

    func testFallsBackToInterimWhenResultBlank() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["", "interim words", "older"],
            fallback: ""
        )
        XCTAssertEqual(text, "interim words")
    }

    func testFallsBackToLastCompletedWhenResultAndInterimBlank() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["   ", "", "last completed"],
            fallback: ""
        )
        XCTAssertEqual(text, "last completed")
    }

    func testWhitespaceOnlyCandidatesAreSkipped() {
        let text = TranscriptionRecordingService.bestTranscript(
            candidates: ["  ", "\n", "\t"],
            fallback: "fallback"
        )
        XCTAssertEqual(text, "fallback")
    }
}
#endif
