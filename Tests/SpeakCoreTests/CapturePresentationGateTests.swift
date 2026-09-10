import Foundation
@testable import SpeakCore
import XCTest

/// The arming → recording rule for issue #983. iOS wiring cannot run on the
/// host, so the rule itself lives here where `swift test` executes it.
final class CapturePresentationGateTests: XCTestCase {
    func testIdleBeforeAnyRun() {
        let gate = CapturePresentationGate()
        XCTAssertEqual(gate.presentation, .idle)
        XCTAssertFalse(gate.isPresentingCapture)
    }

    func testBackendStartAloneStaysPreparing() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        XCTAssertFalse(gate.noteBackendStarted(run: run))
        XCTAssertEqual(gate.presentation, .preparing)
        XCTAssertFalse(gate.isPresentingCapture)
    }

    func testInputAloneStaysPreparing() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        XCTAssertFalse(gate.noteInputObserved(run: run))
        XCTAssertEqual(gate.presentation, .preparing)
    }

    func testStartThenInputPromotesExactlyOnce() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        XCTAssertFalse(gate.noteBackendStarted(run: run))
        XCTAssertTrue(gate.noteInputObserved(run: run))
        XCTAssertEqual(gate.presentation, .capturing)
        // Duplicate notifications from a chatty tap must not re-publish.
        XCTAssertFalse(gate.noteInputObserved(run: run))
        XCTAssertFalse(gate.noteBackendStarted(run: run))
    }

    func testInputBeforeStartReturnsPromotesExactlyOnce() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        XCTAssertFalse(gate.noteInputObserved(run: run))
        XCTAssertTrue(gate.noteBackendStarted(run: run))
        XCTAssertEqual(gate.presentation, .capturing)
        XCTAssertFalse(gate.noteBackendStarted(run: run))
    }

    func testInputFollowedByStartupFailureNeverPresentsCapture() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        XCTAssertFalse(gate.noteInputObserved(run: run))
        gate.finish() // startup threw
        XCTAssertEqual(gate.presentation, .idle)
        XCTAssertFalse(gate.isPresentingCapture)
        // The late tap callback from the failed run stays inert.
        XCTAssertFalse(gate.noteBackendStarted(run: run))
        XCTAssertEqual(gate.presentation, .idle)
    }

    func testCancelledStartupLeavesIdleNotStuckPreparing() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        gate.finish()
        XCTAssertEqual(gate.presentation, .idle)
    }

    func testStaleRunObservationsAreIgnored() {
        var gate = CapturePresentationGate()
        let retired = UUID()
        gate.begin(run: retired)
        XCTAssertFalse(gate.noteBackendStarted(run: retired))

        let replacement = UUID()
        gate.begin(run: replacement)
        XCTAssertFalse(gate.isCurrent(retired))
        // A buffer from the replaced run must never promote its successor.
        XCTAssertFalse(gate.noteInputObserved(run: retired))
        XCTAssertFalse(gate.noteBackendStarted(run: retired))
        XCTAssertEqual(gate.presentation, .preparing)

        XCTAssertFalse(gate.noteBackendStarted(run: replacement))
        XCTAssertTrue(gate.noteInputObserved(run: replacement))
    }

    func testLateCallbacksAfterStopDoNotResurrectCapture() {
        var gate = CapturePresentationGate()
        let run = UUID()
        gate.begin(run: run)
        gate.noteBackendStarted(run: run)
        XCTAssertTrue(gate.noteInputObserved(run: run))
        gate.finish()
        XCTAssertFalse(gate.noteInputObserved(run: run))
        XCTAssertFalse(gate.isPresentingCapture)
    }

    func testImmediateRestartRequiresFreshProof() {
        var gate = CapturePresentationGate()
        let first = UUID()
        gate.begin(run: first)
        gate.noteBackendStarted(run: first)
        gate.noteInputObserved(run: first)
        gate.finish()

        let second = UUID()
        gate.begin(run: second)
        XCTAssertEqual(gate.presentation, .preparing)
        XCTAssertFalse(gate.noteBackendStarted(run: second))
        XCTAssertTrue(gate.noteInputObserved(run: second))
    }

    func testFirstInputSignalMarksOnlyOnce() {
        let signal = FirstInputSignal()
        XCTAssertFalse(signal.hasObserved)
        XCTAssertTrue(signal.markObserved())
        XCTAssertTrue(signal.hasObserved)
        XCTAssertFalse(signal.markObserved())
        XCTAssertFalse(signal.markObserved())
    }

    func testFirstInputSignalIsSafeUnderConcurrentTaps() {
        let signal = FirstInputSignal()
        let marks = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            if signal.markObserved() {
                lock.lock()
                marks.add(true)
                lock.unlock()
            }
        }
        XCTAssertEqual(marks.count, 1)
    }

    func testPreparingMessageDoesNotClaimListening() {
        XCTAssertEqual(CapturePresentationGate.preparingMessage, "Preparing recording...")
    }
}
