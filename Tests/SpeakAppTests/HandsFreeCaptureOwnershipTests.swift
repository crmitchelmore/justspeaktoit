import XCTest

@testable import SpeakApp

/// Hands-free dictation ends and cancels only the capture it started.
///
/// A hands-free capture can end out of band: the user presses stop, and the
/// detector learns of it only when its silence hold elapses. By then the user
/// may already record again by hand, so the stop and cancel closures ask who
/// owns the active session before they touch it.
final class HandsFreeCaptureOwnershipTests: XCTestCase {
    private func makeSession(trigger: SessionTriggerSource) -> ActiveSession {
        ActiveSession(gesture: .uiButton, hotKeyDescription: "Fn", trigger: trigger)
    }

    func testOwnsItsOwnCapture() {
        let session = makeSession(trigger: .handsFree)

        XCTAssertTrue(
            HandsFreeCaptureOwnership.ownsSession(session, isEndingSession: false)
        )
    }

    func testDoesNotOwnARecordingTheUserStartedByHand() {
        for trigger: SessionTriggerSource in [.hold, .doubleTap, .singleTap, .uiButton] {
            let session = makeSession(trigger: trigger)

            XCTAssertFalse(
                HandsFreeCaptureOwnership.ownsSession(session, isEndingSession: false),
                "\(trigger) belongs to the user, so hands-free must leave it alone"
            )
        }
    }

    /// The scenario the guard exists for: the user stopped the hands-free
    /// capture by hand and started their own recording, and only then did the
    /// detector's silence hold elapse.
    func testManualRecordingAfterAnOutOfBandStop_SurvivesTheDetectorStop() {
        let manual = makeSession(trigger: .uiButton)

        XCTAssertFalse(
            HandsFreeCaptureOwnership.ownsSession(manual, isEndingSession: false)
        )
    }

    func testNoSessionIsOwnedByNobody() {
        XCTAssertFalse(
            HandsFreeCaptureOwnership.ownsSession(nil, isEndingSession: false)
        )
    }

    /// A session already on its way out is not ours to end a second time.
    func testASessionThatIsAlreadyEndingIsNotOwned() {
        let session = makeSession(trigger: .handsFree)

        XCTAssertFalse(
            HandsFreeCaptureOwnership.ownsSession(session, isEndingSession: true)
        )
    }
}
