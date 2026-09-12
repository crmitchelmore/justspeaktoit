import XCTest
@testable import SpeakCore

/// Covers the Mac's decision when a phone or watch capture arrives through
/// CloudKit history sync (issue #1007).
final class RemoteTranscriptArrivalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_757_500_000)

    private func input(
        origin: String = "ios",
        age: TimeInterval = 5,
        text: String = "remind Sam about the invoice",
        isNew: Bool = true,
        autoPaste: Bool = false
    ) -> RemoteTranscriptArrival.Input {
        RemoteTranscriptArrival.Input(
            originPlatform: origin,
            createdAt: now.addingTimeInterval(-age),
            text: text,
            isNewToThisMac: isNew,
            autoPasteEnabled: autoPaste
        )
    }

    func testFreshPhoneCaptureNotifies() {
        guard case .notify(let alert) = RemoteTranscriptArrival.decide(input(), now: now) else {
            return XCTFail("expected a notification")
        }
        XCTAssertEqual(alert.title, "New from iPhone")
        XCTAssertEqual(alert.transcript, "remind Sam about the invoice")
    }

    func testWatchCaptureIsNamedAsTheWatch() {
        guard case .notify(let alert) = RemoteTranscriptArrival.decide(
            input(origin: "watchos"), now: now
        ) else {
            return XCTFail("expected a notification")
        }
        XCTAssertEqual(alert.title, "New from Apple Watch")
    }

    /// Notifying is the default; pasting requires the user to have said yes.
    func testAutoPasteIsOptIn() {
        if case .pasteAtCursor = RemoteTranscriptArrival.decide(input(), now: now) {
            XCTFail("auto-paste must not run without the opt-in")
        }
        guard case .pasteAtCursor = RemoteTranscriptArrival.decide(
            input(autoPaste: true), now: now
        ) else {
            return XCTFail("expected auto-paste once opted in")
        }
    }

    func testAMacsOwnEntriesAreIgnored() {
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(input(origin: "macos"), now: now),
            .ignore(.notAPhoneOrWatchCapture)
        )
    }

    func testAlreadyKnownEntriesAreSilent() {
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(input(isNew: false), now: now),
            .ignore(.alreadyKnown)
        )
    }

    /// A first launch downloading a year of history must notify about none of
    /// it, and the opt-in must not turn that into a year of pastes either.
    func testBackfilledHistoryIsSilentEvenWithAutoPasteOn() {
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(input(age: 3600, autoPaste: true), now: now),
            .ignore(.tooOld)
        )
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(
                input(age: RemoteTranscriptArrival.freshnessWindow + 1), now: now
            ),
            .ignore(.tooOld)
        )
        if case .ignore = RemoteTranscriptArrival.decide(
            input(age: RemoteTranscriptArrival.freshnessWindow), now: now
        ) {
            XCTFail("an entry exactly at the boundary is still fresh")
        }
    }

    /// The age check accepted every negative age, so an entry dated far in the
    /// future stayed "fresh" forever and could notify — or, with auto-paste on,
    /// paste at the cursor — on this and every later sync. Only skew a real
    /// pair of clocks can produce is tolerated.
    func testFutureDatedEntriesDoNotBypassTheFreshnessGuard() {
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(
                input(age: -(RemoteTranscriptArrival.futureSkewAllowance + 10)),
                now: now
            ),
            .ignore(.datedInTheFuture)
        )
        XCTAssertEqual(
            RemoteTranscriptArrival.decide(
                input(age: -(60 * 60 * 24 * 365), autoPaste: true),
                now: now
            ),
            .ignore(.datedInTheFuture)
        )
    }

    /// Devices genuinely disagree by seconds; that must still notify.
    func testSmallClockSkewIsStillTreatedAsALiveArrival() {
        guard case .notify = RemoteTranscriptArrival.decide(input(age: -5), now: now) else {
            return XCTFail("a few seconds of clock skew is a live arrival")
        }
    }

    func testEmptyTranscriptsAreIgnored() {
        XCTAssertEqual(RemoteTranscriptArrival.decide(input(text: "   \n"), now: now), .ignore(.noText))
    }

    func testFailedAutoPasteSaysSoInsteadOfClaimingSuccess() {
        let alert = RemoteTranscriptArrival.Alert(title: "New from iPhone", body: "hello", transcript: "hello")
        let failed = RemoteTranscriptArrival.outcomeAlert(
            for: alert, pasted: false, failureReason: "No focused field was detected."
        )
        XCTAssertTrue(failed.body.contains("Could not paste"))
        XCTAssertTrue(failed.body.contains("No focused field"))
        XCTAssertFalse(failed.body.contains("Pasted at your cursor"))

        let pasted = RemoteTranscriptArrival.outcomeAlert(for: alert, pasted: true, failureReason: nil)
        XCTAssertTrue(pasted.body.hasPrefix("Pasted at your cursor"))
    }

    func testFailureWithoutAReasonStillReadsCleanly() {
        let alert = RemoteTranscriptArrival.Alert(title: "t", body: "b", transcript: "b")
        let failed = RemoteTranscriptArrival.outcomeAlert(for: alert, pasted: false, failureReason: nil)
        XCTAssertFalse(failed.body.contains("  "))
    }
}
