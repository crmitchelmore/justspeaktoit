#if os(iOS)
import XCTest
@testable import SpeakiOSLib

/// One owned value decides which stop may deliver and whose polish a waiter
/// reads (#1015), so a superseded stop can never answer a newer run.
final class CapturePolishLedgerTests: XCTestCase {
    func testSupersededPolish_cannotAnswerOrReleaseTheNewerRun() {
        var ledger = CapturePolishLedger()
        let runA = UUID(), runB = UUID()
        let completionA = ledger.beginCompletion()
        ledger.settlePolish(startingFor: runA, polishes: true)
        let completionB = ledger.beginCompletion()
        ledger.settlePolish(startingFor: runB, polishes: true)
        XCTAssertFalse(ledger.isCurrent(completionA))

        ledger.recordPolished("A's text", completion: completionA)
        ledger.finishPolish(run: runA)
        XCTAssertTrue(ledger.isPolishing(run: runB), "A finishing must not release B's waiter")
        XCTAssertNil(ledger.polishedTranscript(forRun: runB))
        XCTAssertNil(ledger.polishedTranscript(forRun: runA), "B owns the state now")

        ledger.recordPolished("B's text", completion: completionB)
        ledger.finishPolish(run: runB)
        XCTAssertEqual(ledger.polishedTranscript(forRun: runB), "B's text")
    }

    func testStopWithoutPolish_clearsThePreviousResultAndFlag() {
        var ledger = CapturePolishLedger()
        let runA = UUID()
        let completion = ledger.beginCompletion()
        ledger.settlePolish(startingFor: runA, polishes: true)
        ledger.recordPolished("A's text", completion: completion)
        ledger.finishPolish(run: runA)

        _ = ledger.beginCompletion()
        ledger.settlePolish(startingFor: UUID(), polishes: false)
        XCTAssertFalse(ledger.isPostProcessing)
        XCTAssertNil(ledger.polishingRunID)
        XCTAssertNil(ledger.polishedTranscript)
    }

    func testRetiredCompletion_isNoLongerCurrentAndRecordsNothing() {
        var ledger = CapturePolishLedger()
        let run = UUID()
        let completion = ledger.beginCompletion()
        ledger.settlePolish(startingFor: run, polishes: true)
        ledger.retireCompletion()
        XCTAssertFalse(ledger.isCurrent(completion))
        ledger.recordPolished("late", completion: completion)
        ledger.finishPolish(run: run)
        XCTAssertNil(ledger.polishedTranscript(forRun: run), "A cancelled stop's polish is not waited on")
    }
}
#endif
