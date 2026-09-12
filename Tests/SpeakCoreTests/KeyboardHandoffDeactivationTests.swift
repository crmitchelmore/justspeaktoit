import Foundation
import XCTest

@testable import SpeakCore

/// What the handoff store guarantees while the keyboard is *not* watching
/// (issue #998, defect class behind #933).
///
/// The keyboard extension is dismissed constantly — the user taps outside the
/// field, switches keyboards, or the host app moves the caret — and every one
/// of those happens after the user has stopped speaking but before the
/// transcript has been inserted. This class pins, with an injected clock and no
/// wall-clock waiting, exactly what survives that gap and what does not.
///
/// The companion class `KeyboardHandoffCrossProcessTests` covers concurrent
/// writes from two processes; this one covers *absence* — one process going
/// quiet for a while and coming back.
///
/// Every store method takes `now:`, so the whole lifetime table
/// (`requestLifetime` 180s, `transcriptionLifetime` 90s, `resultLifetime` 60s)
/// is exercised deterministically.
final class KeyboardHandoffDeactivationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// The containing app's store instance.
    private var app: KeyboardHandoffStore!
    /// The keyboard extension's store instance (independent lock).
    private var ext: KeyboardHandoffStore!

    /// A fixed origin so every assertion below reads as an offset from the
    /// moment the user tapped the microphone.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "keyboard-handoff-deactivation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        ext = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        app = nil
        ext = nil
        super.tearDown()
    }

    /// Drives a request to `.transcribing`: the user held the mic, let go, and
    /// the app is now waiting on the provider. Returns the request identity and
    /// the instant the transcription window opened.
    @discardableResult
    private func startTranscribing(
        targetDocumentIdentifier: UUID? = nil
    ) throws -> (requestID: UUID, transcribingFrom: Date) {
        let request = try ext.createRequest(
            targetDocumentIdentifier: targetDocumentIdentifier,
            now: start
        )
        _ = try app.markRecording(requestID: request.requestID, now: start)
        let finishedAt = start.addingTimeInterval(5)
        _ = try ext.requestFinish(requestID: request.requestID, now: finishedAt)
        _ = try app.markTranscribing(requestID: request.requestID, now: finishedAt)
        return (request.requestID, finishedAt)
    }

    // MARK: - The keyboard goes away mid-transcription

    /// Dismissing the keyboard writes nothing to the store, so the request the
    /// app is still working on must be exactly where it was left, and the app
    /// must still be able to finish it.
    func testKeyboardAwayDuringTranscribing_leavesTheRequestIntactAndCompletable() throws {
        let (requestID, transcribingFrom) = try startTranscribing()

        // The keyboard is dismissed for most of the transcription window.
        let stillWaiting = transcribingFrom.addingTimeInterval(80)
        XCTAssertEqual(
            app.activeRecord(now: stillWaiting)?.phase,
            .transcribing,
            "An absent keyboard must not change the phase the app is working in"
        )

        let completed = try app.complete(
            requestID: requestID,
            transcript: "the words the user actually said",
            now: stillWaiting
        )

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(
            ext.consumeResult(requestID: requestID, now: stillWaiting),
            "the words the user actually said",
            "A keyboard that comes back must find the transcript waiting for it"
        )
    }

    /// The transcription window is real: past it, the request is reported timed
    /// out rather than silently completing into a field the user has left.
    func testKeyboardAwayPastTheTranscriptionWindow_reportsTimedOutAndRefusesCompletion() throws {
        let (requestID, transcribingFrom) = try startTranscribing()

        let tooLate = transcribingFrom
            .addingTimeInterval(KeyboardHandoffStore.transcriptionLifetime + 1)

        let record = try XCTUnwrap(app.activeRecord(now: tooLate))
        XCTAssertEqual(record.phase, .failed)
        XCTAssertEqual(record.failureCode, .timedOut)

        XCTAssertThrowsError(
            try app.complete(requestID: requestID, transcript: "too late", now: tooLate)
        ) { error in
            XCTAssertEqual(error as? KeyboardHandoffStoreError, .invalidTransition)
        }
    }

    /// The exact shape of the loss in issue #933, pinned so it cannot come back
    /// by accident: once the extension issues a cancel, the transcript the app
    /// was about to deliver is unreachable for good. Any dismissal handling
    /// that reaches for `cancel()` while the app is `.transcribing` is throwing
    /// away a finished dictation, and this is what that costs.
    func testCancelWhileTranscribing_makesTheFinishedTranscriptUnreachable() throws {
        let (requestID, transcribingFrom) = try startTranscribing()

        _ = try ext.cancel(requestID: requestID, now: transcribingFrom.addingTimeInterval(1))

        let afterCancel = transcribingFrom.addingTimeInterval(2)
        XCTAssertEqual(app.activeRecord(now: afterCancel)?.phase, .cancelled)
        XCTAssertThrowsError(
            try app.complete(requestID: requestID, transcript: "lost words", now: afterCancel)
        ) { error in
            XCTAssertEqual(error as? KeyboardHandoffStoreError, .invalidTransition)
        }
        XCTAssertNil(
            ext.consumeResult(requestID: requestID, now: afterCancel),
            "A cancelled request must not deliver a transcript later"
        )
    }

    // MARK: - The caret moves while the app is transcribing

    /// The target guard is per-document, not per-keyboard: the same keyboard,
    /// back in a *different* field, must not receive the transcript, and the
    /// original field must still get it.
    func testCaretMovedToAnotherDocument_withholdsTheResultButKeepsItForTheOriginalField() throws {
        let originalDocument = UUID()
        let (requestID, transcribingFrom) = try startTranscribing(
            targetDocumentIdentifier: originalDocument
        )
        let completedAt = transcribingFrom.addingTimeInterval(2)
        _ = try app.complete(requestID: requestID, transcript: "target bound text", now: completedAt)

        XCTAssertNil(
            ext.readyResult(
                requestID: requestID,
                documentIdentifier: UUID(),
                now: completedAt
            ),
            "A transcript bound to one field must never be offered to another"
        )
        XCTAssertEqual(
            ext.readyResult(
                requestID: requestID,
                documentIdentifier: originalDocument,
                now: completedAt
            ),
            "target bound text",
            "The field the user dictated into must still receive the transcript"
        )
    }

    // MARK: - Read, then insert, then clear

    /// Reading must not consume: a keyboard that is dismissed between reading
    /// the transcript and inserting it has to be able to read it again.
    func testReadyResult_survivesRepeatedReadsUntilItIsExplicitlyConsumed() throws {
        let (requestID, transcribingFrom) = try startTranscribing()
        let completedAt = transcribingFrom.addingTimeInterval(2)
        _ = try app.complete(requestID: requestID, transcript: "insert me", now: completedAt)

        let readAt = completedAt.addingTimeInterval(1)
        XCTAssertEqual(ext.readyResult(requestID: requestID, now: readAt), "insert me")
        // The keyboard is dismissed here, before it inserted anything.
        XCTAssertEqual(
            ext.readyResult(requestID: requestID, now: readAt.addingTimeInterval(10)),
            "insert me",
            "A dismissal between read and insert must not lose the transcript"
        )

        XCTAssertEqual(
            ext.consumeResult(requestID: requestID, now: readAt.addingTimeInterval(11)),
            "insert me"
        )
        XCTAssertNil(
            ext.readyResult(requestID: requestID, now: readAt.addingTimeInterval(12)),
            "An explicitly consumed transcript must not be delivered twice"
        )
    }

    /// A finished transcript nobody came back for eventually disappears rather
    /// than being pasted into whatever the user is doing minutes later.
    func testCompletedTranscript_disappearsOnceItsWindowHasPassed() throws {
        let (requestID, transcribingFrom) = try startTranscribing()
        let completedAt = transcribingFrom.addingTimeInterval(2)
        _ = try app.complete(requestID: requestID, transcript: "stale by then", now: completedAt)

        // The record's window is the later of the result and the request
        // windows, so step past both rather than assuming which one binds.
        let longGone = start.addingTimeInterval(
            KeyboardHandoffStore.requestLifetime
                + KeyboardHandoffStore.transcriptionLifetime
                + KeyboardHandoffStore.resultLifetime
        )

        XCTAssertNil(app.activeRecord(now: longGone))
        XCTAssertNil(ext.readyResult(requestID: requestID, now: longGone))
    }
}
