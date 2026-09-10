import Foundation
@testable import SpeakCore
import XCTest

/// Issue #997. A self-test that reports a pass it did not earn is worse than
/// no self-test, so what is locked down here is the failing side: an engine
/// that starts and delivers nothing must never come out green, an unfinished
/// run must never read as a pass, and no path may leave the caller's teardown
/// obligation outstanding.
final class CaptureSelfTestRunTests: XCTestCase {
    // MARK: - Passing requires real audio

    func testARunThatSawARealBufferPasses() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.note(.audioSession, atMilliseconds: 40)
        run.note(.engine, atMilliseconds: 90)
        XCTAssertTrue(run.noteInputBuffer(atMilliseconds: 120))
        let result = run.finish(atMilliseconds: 130)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.observedBuffers, 1)
        XCTAssertEqual(result.stageMilliseconds[.firstInput], 120)
    }

    func testAnEngineThatStartedAndHeardNothingFailsAtFirstInput() {
        // The silent failure this screen exists for. A zero-buffer run that
        // reported "passed" would be the whole feature lying.
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.note(.audioSession, atMilliseconds: 30)
        run.note(.engine, atMilliseconds: 60)
        let result = run.finish(atMilliseconds: 2000)
        XCTAssertEqual(result.outcome, .failed(.firstInput))
        XCTAssertEqual(result.observedBuffers, 0)
    }

    func testAFinishWithNoStagesAtAllNamesTheEarliestMissingBoundary() {
        var run = CaptureSelfTestRun()
        let result = run.finish(atMilliseconds: 10)
        XCTAssertEqual(result.outcome, .failed(.permission))
    }

    func testAFinishAfterTheSessionNamesTheEngine() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.note(.audioSession, atMilliseconds: 20)
        let result = run.finish(atMilliseconds: 900)
        XCTAssertEqual(result.outcome, .failed(.engine))
    }

    // MARK: - Explicit failures and cancellation stick

    func testAnExplicitFailureIsNotOverwrittenByALaterFinish() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.fail(at: .audioSession, atMilliseconds: 50)
        run.note(.engine, atMilliseconds: 60)
        XCTAssertFalse(run.noteInputBuffer(atMilliseconds: 70))
        let result = run.finish(atMilliseconds: 80)
        XCTAssertEqual(result.outcome, .failed(.audioSession))
        XCTAssertEqual(result.observedBuffers, 0, "a terminated run counts nothing further")
        XCTAssertNil(result.stageMilliseconds[.engine])
    }

    func testCancellationSticksAndNeverBecomesAPass() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.note(.audioSession, atMilliseconds: 20)
        run.note(.engine, atMilliseconds: 40)
        run.cancel(atMilliseconds: 50)
        let result = run.finish(atMilliseconds: 60)
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testAnUnfinishedRunReadsAsCancelledRatherThanPassed() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.noteInputBuffer(atMilliseconds: 30)
        XCTAssertEqual(run.result().outcome, .cancelled)
    }

    // MARK: - The microphone is never left open

    func testTeardownIsOwedFromTheSessionOnwardsAndDischargedByEveryEnding() {
        for ending in ["finish", "fail", "cancel"] {
            var run = CaptureSelfTestRun()
            run.note(.permission, atMilliseconds: 1)
            XCTAssertFalse(run.owesTeardown, "nothing is open before the session")
            run.note(.audioSession, atMilliseconds: 20)
            XCTAssertTrue(run.owesTeardown, "the session is open")
            switch ending {
            case "finish": _ = run.finish(atMilliseconds: 100)
            case "fail": run.fail(at: .engine, atMilliseconds: 100)
            default: run.cancel(atMilliseconds: 100)
            }
            XCTAssertFalse(run.owesTeardown, "\(ending) left the obligation outstanding")
            XCTAssertTrue(run.isFinished)
        }
    }

    func testTheOverallDeadlineIsReachableSoAHungStepStillTearsDown() {
        let run = CaptureSelfTestRun(deadlineSeconds: 8)
        XCTAssertFalse(run.hasPassedDeadline(atMilliseconds: 7999))
        XCTAssertTrue(run.hasPassedDeadline(atMilliseconds: 8000))
    }

    // MARK: - Boundaries are measured once

    func testARepeatedBoundaryDoesNotMove() {
        var run = CaptureSelfTestRun()
        run.note(.engine, atMilliseconds: 100)
        run.note(.engine, atMilliseconds: 900)
        XCTAssertEqual(run.result().stageMilliseconds[.engine], 100)
    }

    func testAStageThatWasNeverReachedIsAbsentRatherThanZero() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 5)
        XCTAssertNil(run.result().stageMilliseconds[.engine])
    }

    func testNegativeElapsedIsClampedRatherThanRecordedBackwards() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: -50)
        XCTAssertEqual(run.result().stageMilliseconds[.permission], 0)
    }

    func testMoreThanOneRequiredBufferIsNotSatisfiedByTheFirst() {
        var run = CaptureSelfTestRun(requiredBuffers: 3)
        XCTAssertFalse(run.noteInputBuffer(atMilliseconds: 10))
        XCTAssertFalse(run.noteInputBuffer(atMilliseconds: 20))
        XCTAssertTrue(run.noteInputBuffer(atMilliseconds: 30))
        XCTAssertEqual(run.finish(atMilliseconds: 40).outcome, .passed)
    }

    // MARK: - Honesty about the gaps

    func testEveryResultCarriesWhatItCouldNotSettle() {
        var run = CaptureSelfTestRun()
        run.note(.permission, atMilliseconds: 1)
        run.note(.audioSession, atMilliseconds: 2)
        run.note(.engine, atMilliseconds: 3)
        run.noteInputBuffer(atMilliseconds: 4)
        let result = run.finish(atMilliseconds: 5)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(Set(result.limits), Set(CaptureSelfTestLimit.allCases))
        XCTAssertFalse(result.limits.isEmpty, "a pass must still say what it did not prove")
    }

    func testTheLimitsNameTheThingsThatNeedRealSpeechOrRealHardware() {
        XCTAssertTrue(CaptureSelfTestLimit.allCases.contains(.transcriptionAccuracy))
        XCTAssertTrue(CaptureSelfTestLimit.allCases.contains(.providerRoundTrip))
        XCTAssertTrue(CaptureSelfTestLimit.allCases.contains(.lockedDeviceCredentialAccess))
        XCTAssertTrue(CaptureSelfTestLimit.allCases.contains(.headlessTriggerDelivery))
        for limit in CaptureSelfTestLimit.allCases {
            XCTAssertFalse(limit.explanation.isEmpty, "\(limit)")
        }
    }

    func testEveryStageExplainsWhatFailingThereMeans() {
        var seen: Set<String> = []
        for stage in CaptureSelfTestStage.allCases {
            XCTAssertFalse(stage.label.isEmpty)
            XCTAssertTrue(seen.insert(stage.failureMeaning).inserted, "\(stage) reuses another stage's words")
        }
    }

    // MARK: - Policy

    func testTheMicrophoneWindowIsShortAndTheCeilingIsLonger() {
        XCTAssertLessThanOrEqual(CaptureSelfTestPolicy.inputWindowSeconds, 2)
        XCTAssertGreaterThan(
            CaptureSelfTestPolicy.overallDeadlineSeconds,
            CaptureSelfTestPolicy.inputWindowSeconds
        )
    }
}
