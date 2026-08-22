import XCTest

@testable import SpeakApp

/// The replacement-semantic projection behind `WhisperKitLiveController`
/// (issue #713): confirmed text plus exactly one rendering of the audio after
/// it, never the unconfirmed window and the hypothesis that re-decodes it.
final class WhisperKitTranscriptProjectionTests: XCTestCase {
    // MARK: - Display text

    func testDisplayText_hypothesisReplacesUnconfirmedWindow() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 2, " The cat")],
            unconfirmedSegments: [segment(2, 3, " sat on")],
            currentText: " sat on the"
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: state), "The cat sat on the")
    }

    func testDisplayText_fallsBackToUnconfirmedSegmentsWithoutHypothesis() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 2, " The cat")],
            unconfirmedSegments: [segment(2, 3, " sat on"), segment(3, 4, " the mat")],
            currentText: ""
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: state), "The cat sat on the mat")
    }

    func testDisplayText_treatsWaitingPlaceholderAsNoHypothesis() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [],
            unconfirmedSegments: [segment(0, 1, " Hello")],
            currentText: WhisperKitTranscriptProjection.waitingPlaceholder
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: state), "Hello")

        let empty = WhisperKitTranscriptState(currentText: WhisperKitTranscriptProjection.waitingPlaceholder)
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: empty), "")
    }

    func testDisplayText_dropsUnconfirmedSegmentsAlreadyCoveredByConfirmedTiming() {
        // Mid-publication state: the segment was appended to the confirmed
        // array but the unconfirmed array has not been replaced yet.
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 2, " The cat"), segment(2, 3, " sat on")],
            unconfirmedSegments: [segment(2, 3, " sat on"), segment(3, 4, " the")],
            currentText: ""
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: state), "The cat sat on the")
    }

    func testDisplayText_cleansBlankAudioMarkersAndWhitespace() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 1, " [BLANK_AUDIO] "), segment(1, 2, "  Hello\n")],
            unconfirmedSegments: [],
            currentText: "  there   [blank_audio]"
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.displayText(for: state), "Hello there")
    }

    // MARK: - Final text

    func testFinalText_appendsTailDecodeToConfirmedText() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 2, " Hello there")],
            unconfirmedSegments: [segment(2, 2.8, " how")],
            currentText: " how are"
        )
        XCTAssertEqual(
            WhisperKitTranscriptProjection.finalText(
                for: state,
                tailText: " how are you",
                displayedText: "Hello there how are"
            ),
            "Hello there how are you"
        )
        XCTAssertEqual(WhisperKitTranscriptProjection.tailStart(for: state), 2)
    }

    func testFinalText_keepsDisplayedTextWhenTailDecodeIsEmpty() {
        let state = WhisperKitTranscriptState(
            confirmedSegments: [segment(0, 2, " Hello")],
            unconfirmedSegments: [],
            currentText: " world"
        )
        for tail in ["", "   ", " [BLANK_AUDIO] "] {
            XCTAssertEqual(
                WhisperKitTranscriptProjection.finalText(
                    for: state,
                    tailText: tail,
                    displayedText: "Hello world"
                ),
                "Hello world"
            )
        }
    }

    func testTailStart_isZeroWithoutConfirmedSegments() {
        XCTAssertEqual(WhisperKitTranscriptProjection.tailStart(for: WhisperKitTranscriptState()), 0)
    }

    // MARK: - Tail sample range

    func testTailSampleRange_coversWholeBufferWhenNothingIsConfirmed() {
        XCTAssertEqual(tailSampleRange(sampleCount: 8000, confirmedEndSeconds: 0), 0..<8000)
    }

    func testTailSampleRange_startsAtConfirmedEnd() {
        XCTAssertEqual(tailSampleRange(sampleCount: 48_000, confirmedEndSeconds: 2.5), 40_000..<48_000)
    }

    func testTailSampleRange_isNilForTailsTooShortToHoldSpeech() {
        XCTAssertNil(tailSampleRange(sampleCount: 1000, confirmedEndSeconds: 0))
        XCTAssertNil(tailSampleRange(sampleCount: 16_000, confirmedEndSeconds: 1))
        XCTAssertNil(tailSampleRange(sampleCount: 16_000, confirmedEndSeconds: 2))
        XCTAssertNil(tailSampleRange(sampleCount: 0, confirmedEndSeconds: 0))
    }

    func testTailSampleRange_clampsNegativeConfirmedEnd() {
        XCTAssertEqual(tailSampleRange(sampleCount: 4000, confirmedEndSeconds: -1), 0..<4000)
    }

    private func tailSampleRange(sampleCount: Int, confirmedEndSeconds: Float) -> Range<Int>? {
        WhisperKitTranscriptProjection.tailSampleRange(
            sampleCount: sampleCount,
            confirmedEndSeconds: confirmedEndSeconds,
            sampleRate: 16_000
        )
    }

    // MARK: - Helpers

    private func segment(_ start: Float, _ end: Float, _ text: String) -> WhisperKitSegment {
        WhisperKitSegment(start: start, end: end, text: text)
    }
}
