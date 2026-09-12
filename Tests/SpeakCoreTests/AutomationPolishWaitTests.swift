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

/// The 12-second polish budget used to start *after* the stop had already
/// drained the transcriber, written History and applied the destination — so a
/// slow stop plus a full wait could push the intent past the system's limit
/// and return nothing at all, not even the raw transcript.
final class PolishWaitBudgetTests: XCTestCase {
    func testAFastStopLeavesTheFullRequestedWait() {
        XCTAssertEqual(
            AutomationIntentSupport.PolishWait.remaining(
                requested: AutomationIntentSupport.PolishWait.defaultSeconds,
                elapsed: 1
            ),
            AutomationIntentSupport.PolishWait.defaultSeconds
        )
    }

    func testASlowStopShortensTheWaitRatherThanBeingFollowedByAFullOne() {
        let remaining = AutomationIntentSupport.PolishWait.remaining(requested: 12, elapsed: 20)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, 12)
        XCTAssertLessThanOrEqual(
            20 + remaining,
            AutomationIntentSupport.PolishWait.operationBudgetSeconds
        )
    }

    func testAStopThatUsedTheWholeBudgetLeavesNoWaitAtAll() {
        XCTAssertEqual(AutomationIntentSupport.PolishWait.remaining(requested: 12, elapsed: 25), 0)
        XCTAssertEqual(AutomationIntentSupport.PolishWait.remaining(requested: 12, elapsed: 600), 0)
    }

    /// The wait never adds to an overrun. Below the budget the stop and the
    /// wait together stay inside it with the return reserve intact; past it
    /// the wait is zero, because there is nothing left to spend.
    func testTheWaitNeverAddsToAnOverrun() {
        let ceiling = AutomationIntentSupport.PolishWait.operationBudgetSeconds
            - AutomationIntentSupport.PolishWait.returnReserveSeconds
        for elapsed in stride(from: 0.0, through: 40.0, by: 0.5) {
            let remaining = AutomationIntentSupport.PolishWait.remaining(
                requested: AutomationIntentSupport.PolishWait.maximumSeconds,
                elapsed: elapsed
            )
            if elapsed >= ceiling {
                XCTAssertEqual(remaining, 0, "a spent budget must buy no wait at all")
            } else {
                XCTAssertLessThanOrEqual(
                    elapsed + remaining,
                    ceiling + 0.000_1,
                    "elapsed \(elapsed) + wait \(remaining) overran the budget"
                )
            }
        }
    }

    func testTheRequestedWaitIsStillClamped() {
        XCTAssertEqual(
            AutomationIntentSupport.PolishWait.remaining(requested: 600, elapsed: 0),
            AutomationIntentSupport.PolishWait.maximumSeconds
        )
        XCTAssertEqual(AutomationIntentSupport.PolishWait.remaining(requested: 0, elapsed: 0), 0)
    }

    func testMonotonicElapsedNeverGoesBackwards() {
        let start = MonotonicClock.now()
        let first = MonotonicClock.elapsedSeconds(since: start)
        let second = MonotonicClock.elapsedSeconds(since: start)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
