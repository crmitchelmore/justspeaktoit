import XCTest
@testable import SpeakCore

/// Issue #1015: under "Clipboard and Polish" the Shortcut chain got the raw
/// transcript while the clipboard ended up holding the polished one, and the
/// user could not tell which they had. `Wait For Polish` makes the two agree.
///
/// The rule these tests hold: waiting can improve the answer but must never
/// make it worse. A polish that fails, times out or returns nothing falls back
/// to the raw transcript — never to an empty string, never to a placeholder.
final class AutomationPolishWaitTests: XCTestCase {
    // MARK: - The bound on the wait

    func testTheWaitIsCappedSoAnIntentIsNeverKilledForOverrunning() {
        XCTAssertEqual(
            AutomationIntentSupport.PolishWait.clamped(600),
            AutomationIntentSupport.PolishWait.maximumSeconds
        )
    }

    func testTheDefaultWaitIsWithinTheCap() {
        XCTAssertLessThanOrEqual(
            AutomationIntentSupport.PolishWait.defaultSeconds,
            AutomationIntentSupport.PolishWait.maximumSeconds
        )
        XCTAssertGreaterThan(AutomationIntentSupport.PolishWait.defaultSeconds, 0)
    }

    func testANonPositiveWaitMeansDoNotWait() {
        XCTAssertEqual(AutomationIntentSupport.PolishWait.clamped(0), 0)
        XCTAssertEqual(AutomationIntentSupport.PolishWait.clamped(-5), 0)
    }

    func testAShorterWaitIsHonouredRatherThanRaised() {
        XCTAssertEqual(AutomationIntentSupport.PolishWait.clamped(2), 2)
    }

    // MARK: - What comes back

    func testNotWaitingReturnsTheRawTranscriptEvenWhenAPolishExists() {
        // The default, and every Shortcut saved before the parameter existed:
        // stop, return the raw text, exactly as before.
        XCTAssertEqual(
            AutomationIntentSupport.transcriptAfterPolishWait(
                raw: "raw text",
                polished: "polished text",
                didWait: false
            ),
            "raw text"
        )
    }

    func testWaitingReturnsThePolishedTranscript() {
        XCTAssertEqual(
            AutomationIntentSupport.transcriptAfterPolishWait(
                raw: "raw text",
                polished: "polished text",
                didWait: true
            ),
            "polished text"
        )
    }

    func testAPolishThatNeverLandedFallsBackToTheRawTranscript() {
        XCTAssertEqual(
            AutomationIntentSupport.transcriptAfterPolishWait(
                raw: "raw text",
                polished: nil,
                didWait: true
            ),
            "raw text"
        )
    }

    func testABlankPolishFallsBackRatherThanReturningNothing() {
        XCTAssertEqual(
            AutomationIntentSupport.transcriptAfterPolishWait(
                raw: "raw text",
                polished: "   \n ",
                didWait: true
            ),
            "raw text"
        )
    }

    func testAnEmptyRecordingIsStillAFailureWhetherOrNotWeWaited() {
        // A duplicate stop and a silent recording both finish empty. Handing
        // "" downstream as a success is what the caller must not do.
        XCTAssertNil(
            AutomationIntentSupport.transcriptAfterPolishWait(raw: "", polished: nil, didWait: true)
        )
        XCTAssertNil(
            AutomationIntentSupport.transcriptAfterPolishWait(raw: " ", polished: nil, didWait: false)
        )
    }

    func testAPolishedResultRescuesAnEmptyRawTranscriptWhenWeWaited() {
        XCTAssertEqual(
            AutomationIntentSupport.transcriptAfterPolishWait(
                raw: "",
                polished: "polished text",
                didWait: true
            ),
            "polished text"
        )
    }
}
