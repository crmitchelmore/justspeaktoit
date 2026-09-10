import XCTest
@testable import SpeakCore

/// The whole "is this terminal, and has the user already been told?" decision
/// for a capture that failed to start (issue #944).
final class CaptureStartFailurePolicyTests: XCTestCase {
    private func disposition(
        _ description: String? = "Microphone permission is required for transcription.",
        cancelled: Bool = false,
        later: Bool = false,
        ownedElsewhere: Bool = false
    ) -> CaptureStartFailurePolicy.Disposition {
        CaptureStartFailurePolicy.disposition(
            errorDescription: description,
            isCancellation: cancelled,
            laterCaptureInFlight: later,
            microphoneOwnedElsewhere: ownedElsewhere
        )
    }

    // MARK: - Terminal

    func testTerminalFailureIsSurfacedWithItsOwnMessage() {
        XCTAssertEqual(
            disposition(),
            .surface("Microphone permission is required for transcription.")
        )
    }

    func testFailureWithNoQuotableMessageStillSaysTheRecordingDidNotStart() {
        // Truthful rather than cheerful: the press did nothing, and the alert
        // has to say so even when the error has no text of its own.
        XCTAssertEqual(
            disposition(nil),
            .surface(CaptureLinkFailure.recordingFailed.localizedDescription)
        )
        XCTAssertEqual(disposition("   \n "), disposition(nil))
    }

    func testMessageIsTrimmedRatherThanPresentedWithStrayWhitespace() {
        XCTAssertEqual(disposition("  Recognition failed: no route.\n"), .surface("Recognition failed: no route."))
    }

    // MARK: - Silent

    func testCancellationIsNeverSurfaced() {
        // Pressing the quick action again to cancel a start in flight is the
        // user getting what they asked for.
        XCTAssertEqual(disposition(cancelled: true), .logOnly(.cancelled))
    }

    func testSupersededRunIsNeverSurfaced() {
        // A newer capture is running; attaching an old failure to it would be
        // a lie about a session that is working.
        XCTAssertEqual(disposition(later: true), .logOnly(.superseded))
    }

    func testMicrophoneOwnedByTheInAppRecorderIsLoggedNotAlerted() {
        XCTAssertEqual(disposition(ownedElsewhere: true), .logOnly(.ownedByAnotherSurface))
    }

    func testCancellationWinsOverEveryOtherSignal() {
        XCTAssertEqual(
            disposition(cancelled: true, later: true, ownedElsewhere: true),
            .logOnly(.cancelled)
        )
    }

    func testEverySilentDispositionHasNoPresentedMessage() {
        for silent in [disposition(cancelled: true), disposition(later: true), disposition(ownedElsewhere: true)] {
            XCTAssertNil(silent.presentedMessage)
        }
        XCTAssertNotNil(disposition().presentedMessage)
    }

    // MARK: - Presentation, one alert per failure

    func testAFreshFailureIsPresented() {
        XCTAssertTrue(CaptureStartFailurePolicy.shouldPresent("Microphone denied.", lastPresented: nil))
    }

    func testTheSameFailureIsNotPresentedTwice() {
        // The change observer and the on-appear read both run for a warm
        // failure; only one alert may come out of them.
        XCTAssertFalse(
            CaptureStartFailurePolicy.shouldPresent("Microphone denied.", lastPresented: "Microphone denied.")
        )
    }

    func testADifferentFailureIsPresentedOverAnOlderOne() {
        XCTAssertTrue(
            CaptureStartFailurePolicy.shouldPresent("Recognizer unavailable.", lastPresented: "Microphone denied.")
        )
    }

    func testClearedErrorPresentsNothingSoASuccessfulStartInheritsNoAlert() {
        XCTAssertFalse(CaptureStartFailurePolicy.shouldPresent(nil, lastPresented: "Microphone denied."))
        XCTAssertFalse(CaptureStartFailurePolicy.shouldPresent("", lastPresented: nil))
    }

    func testTheSameFailureRepeatedAfterAClearIsPresentedAgain() {
        // A start clears the published error before it can fail again, so the
        // second denial is a new event and must alert.
        var lastPresented: String?
        let message = "Microphone permission is required for transcription."
        XCTAssertTrue(CaptureStartFailurePolicy.shouldPresent(message, lastPresented: lastPresented))
        lastPresented = message
        XCTAssertFalse(CaptureStartFailurePolicy.shouldPresent(message, lastPresented: lastPresented))
        XCTAssertFalse(CaptureStartFailurePolicy.shouldPresent(nil, lastPresented: lastPresented))
        lastPresented = nil
        XCTAssertTrue(CaptureStartFailurePolicy.shouldPresent(message, lastPresented: lastPresented))
    }
}
