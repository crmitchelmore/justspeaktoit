import Foundation
import XCTest
@testable import SpeakiOSLib

final class CaptureRunLedgerTests: XCTestCase {
    func testCompletionIsTaggedWithTheRunAndRetiresIt() {
        var ledger = CaptureRunLedger()
        let run = UUID()
        ledger.begin(run)
        XCTAssertEqual(ledger.currentRunID, run)
        XCTAssertNil(ledger.completedTranscript(forRun: run), "An unsettled run has no answer yet")

        XCTAssertEqual(ledger.complete(with: "hello"), run)
        XCTAssertNil(ledger.currentRunID)
        XCTAssertEqual(ledger.completedTranscript(forRun: run), "hello")
    }

    func testEmptyTranscriptIsARealAnswerAndNotReplacedByAnOlderOne() {
        var ledger = CaptureRunLedger()
        let first = UUID(), second = UUID()
        ledger.begin(first)
        ledger.complete(with: "older words")
        ledger.begin(second)
        ledger.complete(with: "")

        XCTAssertEqual(ledger.completedTranscript(forRun: second), "")
        XCTAssertNil(ledger.completedTranscript(forRun: first), "A later run supersedes the earlier answer")
    }

    func testSecondCompletionWithoutARunInFlightIsANoOp() {
        var ledger = CaptureRunLedger()
        let run = UUID()
        ledger.begin(run)
        ledger.complete(with: "first")

        XCTAssertNil(ledger.complete(with: "late duplicate"))
        XCTAssertEqual(ledger.completedTranscript(forRun: run), "first")
        XCTAssertEqual(ledger.lastCompletion, CaptureRunLedger.Completion(runID: run, text: "first"))
    }

    func testWaiterForAnotherRunGetsNothing() {
        var ledger = CaptureRunLedger()
        ledger.begin(UUID())
        ledger.complete(with: "someone else's words")
        XCTAssertNil(ledger.completedTranscript(forRun: UUID()))
    }
}
