import Foundation
import XCTest

@testable import SpeakCore

/// Marked text is provisional text sitting in the *user's* document. The one
/// requirement that outranks everything else in issue #1004 is that it is
/// never left there. These tests walk every way a run can end and assert that
/// each produces exactly one resolving action, and that repeating any of them
/// produces none.
final class KeyboardMarkedTextTests: XCTestCase {
    private func streaming() -> KeyboardMarkedTextSession {
        KeyboardMarkedTextSession(streamsMarkedText: true, isSecureField: false)
    }

    // MARK: - The happy path

    func testInterims_markAndTheFinalTranscriptFinalisesInPlace() {
        var session = streaming()
        XCTAssertEqual(session.interim("hello"), .mark("hello"))
        XCTAssertEqual(session.interim("hello there"), .mark("hello there"))
        XCTAssertEqual(session.finish("Hello there."), .finalise("Hello there."))
        XCTAssertNil(session.outstanding)
    }

    func testRepeatedInterim_doesNotRewriteTheSameText() {
        var session = streaming()
        XCTAssertEqual(session.interim("hello"), .mark("hello"))
        XCTAssertEqual(session.interim("hello"), .none)
        XCTAssertEqual(session.interim("  hello  "), .none)
    }

    func testEmptyInterim_neverBlanksTextAlreadyShown() {
        // Providers emit empty hypotheses mid-utterance; clearing the field on
        // one of those would flicker the user's words in and out.
        var session = streaming()
        XCTAssertEqual(session.interim("hello"), .mark("hello"))
        XCTAssertEqual(session.interim(""), .none)
        XCTAssertEqual(session.outstanding, "hello")
    }

    // MARK: - Never into a secure field

    func testSecureField_isNeverMarkedIntoAndFinishesByPlainInsertion() {
        var session = KeyboardMarkedTextSession(streamsMarkedText: true, isSecureField: true)
        XCTAssertEqual(session.interim("hunter2"), .none)
        XCTAssertNil(session.outstanding)
        // `.none` from `finish` is the caller's instruction to insert normally.
        XCTAssertEqual(session.finish("hunter2"), .none)
    }

    func testStreamingOff_behavesExactlyAsBeforeTheFeature() {
        var session = KeyboardMarkedTextSession(streamsMarkedText: false, isSecureField: false)
        XCTAssertEqual(session.interim("hello"), .none)
        XCTAssertEqual(session.finish("Hello."), .none)
    }

    // MARK: - Abandonment: every ending resolves the field

    func testCancellation_takesTheProvisionalTextBackOut() {
        var session = streaming()
        _ = session.interim("hello")
        XCTAssertEqual(session.abandon(), .clear)
        XCTAssertNil(session.outstanding)
    }

    func testDismissal_thenAReturningCompletion_insertsOnceAndNeverTwice() {
        // #1030 keeps a finishing request alive across keyboard dismissal, so
        // the transcript still arrives on the next appearance. It must arrive
        // as a plain insertion, because the marked text was already cleared.
        var session = streaming()
        _ = session.interim("hello")
        XCTAssertEqual(session.abandon(), .clear)
        XCTAssertEqual(session.finish("Hello there."), .none)
    }

    func testDocumentChange_clearsAndStopsStreamingForGood() {
        var session = streaming()
        _ = session.interim("hello")
        XCTAssertEqual(session.documentChanged(), .clear)
        XCTAssertFalse(session.isStreaming)
        // The run does not resume streaming into the new field.
        XCTAssertEqual(session.interim("hello again"), .none)
        XCTAssertEqual(session.finish("Hello again."), .none)
    }

    func testCaretMove_clearsAndFallsBackToPlainInsertion() {
        var session = streaming()
        _ = session.interim("hello")
        XCTAssertEqual(session.caretMoved(), .clear)
        XCTAssertEqual(session.interim("hello there"), .none)
        XCTAssertEqual(session.finish("Hello there."), .none)
    }

    func testEveryEnding_isIdempotent() {
        for ending in ["abandon", "documentChanged", "caretMoved"] {
            var session = streaming()
            _ = session.interim("hello")
            let first: KeyboardMarkedTextSession.Action
            let second: KeyboardMarkedTextSession.Action
            switch ending {
            case "documentChanged":
                first = session.documentChanged()
                second = session.documentChanged()
            case "caretMoved":
                first = session.caretMoved()
                second = session.caretMoved()
            default:
                first = session.abandon()
                second = session.abandon()
            }
            XCTAssertEqual(first, .clear, ending)
            XCTAssertEqual(second, .none, "\(ending) must not clear twice")
        }
    }

    func testFinish_isIdempotent() {
        // A completed record is read again on the next poll tick; the words
        // must not be committed a second time.
        var session = streaming()
        _ = session.interim("hello")
        XCTAssertEqual(session.finish("Hello."), .finalise("Hello."))
        XCTAssertEqual(session.finish("Hello."), .none)
    }

    func testAbandonAfterFinish_isANoOp() {
        // Deactivation follows every insertion. It must not clear text the
        // user has just had committed.
        var session = streaming()
        _ = session.interim("hello")
        _ = session.finish("Hello.")
        XCTAssertEqual(session.abandon(), .none)
    }

    func testAbandonWithNothingShown_isANoOp() {
        // A run that never produced a partial must not touch the field at all.
        var session = streaming()
        XCTAssertEqual(session.abandon(), .none)
    }
}
