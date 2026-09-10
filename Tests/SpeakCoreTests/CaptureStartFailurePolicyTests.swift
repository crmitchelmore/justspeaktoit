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

    private static let first = UUID()
    private static let second = UUID()

    func testAFreshFailureIsPresented() {
        XCTAssertTrue(CaptureStartFailurePolicy.shouldPresent(token: Self.first, lastPresented: nil))
    }

    func testTheSamePublicationIsNotPresentedTwice() {
        // The change observer and the on-appear read both run for a warm
        // failure; only one alert may come out of them.
        XCTAssertFalse(
            CaptureStartFailurePolicy.shouldPresent(token: Self.first, lastPresented: Self.first)
        )
    }

    func testALaterFailureIsPresentedOverAnOlderOne() {
        XCTAssertTrue(
            CaptureStartFailurePolicy.shouldPresent(token: Self.second, lastPresented: Self.first)
        )
    }

    func testClearedErrorPresentsNothingSoASuccessfulStartInheritsNoAlert() {
        XCTAssertFalse(CaptureStartFailurePolicy.shouldPresent(token: nil, lastPresented: Self.first))
    }

    /// The reason the identity is the publication and not its text: two
    /// refusals can read identically. A second capture link refused for the
    /// same reason, after the first alert was dismissed and with no start in
    /// between to clear anything, is a new event and must be shown.
    func testATextuallyIdenticalLaterFailureIsStillPresented() {
        let firstPublication = UUID()
        let secondPublication = UUID()
        var lastPresented: UUID?

        XCTAssertTrue(
            CaptureStartFailurePolicy.shouldPresent(token: firstPublication, lastPresented: lastPresented)
        )
        lastPresented = firstPublication
        XCTAssertFalse(
            CaptureStartFailurePolicy.shouldPresent(token: firstPublication, lastPresented: lastPresented)
        )
        // Same words, new publication, nothing cleared in between.
        XCTAssertTrue(
            CaptureStartFailurePolicy.shouldPresent(token: secondPublication, lastPresented: lastPresented),
            "A repeated refusal must not be swallowed because it reads the same"
        )
    }

    // MARK: - The presented message

    func testTheMessageThePolicyChoseIsTheMessageThatIsPublished() throws {
        let padded = CaptureStartFailurePolicy.disposition(
            errorDescription: "  Microphone denied.  ",
            isCancellation: false,
            laterCaptureInFlight: false,
            microphoneOwnedElsewhere: false
        )
        let failure = CaptureStartFailurePolicy.PresentedFailure(
            message: try XCTUnwrap(padded.presentedMessage)
        )
        XCTAssertEqual(failure.errorDescription, "Microphone denied.")
        XCTAssertEqual(failure.localizedDescription, "Microphone denied.")
    }

    func testAnUnquotableErrorIsPublishedAsTheFallbackRatherThanBlank() throws {
        for description in [nil, "", "   \n "] {
            let message = try XCTUnwrap(
                CaptureStartFailurePolicy.disposition(
                    errorDescription: description,
                    isCancellation: false,
                    laterCaptureInFlight: false,
                    microphoneOwnedElsewhere: false
                ).presentedMessage
            )
            XCTAssertEqual(message, CaptureLinkFailure.recordingFailed.localizedDescription)
            XCTAssertFalse(
                CaptureStartFailurePolicy.PresentedFailure(message: message)
                    .localizedDescription.isEmpty,
                "A failed capture must never reach the alert blank"
            )
        }
    }
}
