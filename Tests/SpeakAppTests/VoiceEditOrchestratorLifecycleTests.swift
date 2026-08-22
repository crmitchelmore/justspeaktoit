import XCTest

@testable import SpeakApp

/// Shared-capture reservation and awaited cancellation (issue #673): Voice Edit
/// must never start on top of dictation, must hold capture until its own
/// teardown is done, and a restart right after Escape must not meet the
/// previous session's recorder.
@MainActor
final class VoiceEditOrchestratorLifecycleTests: XCTestCase {
    private typealias Harness = VoiceEditOrchestratorHarness

    // MARK: - Reservation

    func testReservationHeldByDictation_failsBeforeTouchingCapture() async {
        let harness = Harness()
        harness.reservationAvailable = false

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.events, [.failed(.dictationBusy)])
        XCTAssertEqual(harness.reserveCount, 1)
        XCTAssertEqual(harness.captureCount, 0)
        XCTAssertEqual(harness.startCount, 0)
        XCTAssertEqual(harness.releaseCount, 0, "Nothing was reserved, so nothing is released")
    }

    func testReservation_isHeldForTheWholeSessionAndReleasedOnSuccess() async {
        let harness = Harness()
        await harness.orchestrator.toggle()
        XCTAssertEqual(harness.reserveCount, 1)
        XCTAssertEqual(harness.releaseCount, 0, "Held while listening")

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.releaseCount, 1)
    }

    func testReservation_isReleasedAfterAFailedStart() async {
        let harness = Harness()
        harness.selection = nil

        await harness.orchestrator.toggle()

        XCTAssertEqual(harness.reserveCount, 1)
        XCTAssertEqual(harness.releaseCount, 1)
    }

    func testReservation_isReleasedAfterCancel() async {
        let harness = Harness()
        await harness.orchestrator.toggle()

        await harness.orchestrator.cancel()

        XCTAssertEqual(harness.releaseCount, 1)
    }

    // MARK: - Cancellation

    func testCancelDuringListening_stopsRecordingAndEmitsCancelled() async {
        let harness = Harness()
        await harness.orchestrator.toggle()

        await harness.orchestrator.cancel()

        XCTAssertEqual(harness.cancelCount, 1)
        XCTAssertEqual(harness.events.last, .cancelled)
        XCTAssertEqual(harness.orchestrator.phase, .idle)
        XCTAssertEqual(harness.finishCount, 0)
    }

    func testCancelWhenIdle_isANoOp() async {
        let harness = Harness()

        await harness.orchestrator.cancel()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(harness.cancelCount, 0)
    }

    func testCancel_returnsToIdleOnlyAfterTeardownCompletes() async {
        let harness = Harness()
        await harness.orchestrator.toggle()
        let teardownEntered = expectation(description: "teardown entered")
        let gate = VoiceEditTestGate()
        harness.cancelGate = {
            teardownEntered.fulfill()
            await gate.wait()
        }

        let cancel = Task { await harness.orchestrator.cancel() }
        await fulfillment(of: [teardownEntered], timeout: 2)

        XCTAssertEqual(harness.orchestrator.phase, .cancelling)
        XCTAssertFalse(harness.events.contains(.cancelled), "Cancelled is reported only once teardown is done")
        XCTAssertEqual(harness.releaseCount, 0, "Capture stays reserved until the recorder is released")

        gate.open()
        await cancel.value

        XCTAssertEqual(harness.orchestrator.phase, .idle)
        XCTAssertEqual(harness.events.last, .cancelled)
        XCTAssertEqual(harness.releaseCount, 1)
    }

    func testRestartDuringCancel_waitsForTeardownThenStartsFresh() async {
        let harness = Harness()
        await harness.orchestrator.toggle()
        let teardownEntered = expectation(description: "teardown entered")
        let gate = VoiceEditTestGate()
        harness.cancelGate = {
            teardownEntered.fulfill()
            await gate.wait()
        }

        let cancel = Task { await harness.orchestrator.cancel() }
        await fulfillment(of: [teardownEntered], timeout: 2)
        let restart = Task { await harness.orchestrator.toggle() }
        await Task.yield()

        XCTAssertEqual(harness.startCount, 1, "The restart must not start recording over the old recorder")
        XCTAssertEqual(harness.captureCount, 1)

        gate.open()
        await cancel.value
        await restart.value

        XCTAssertEqual(harness.orchestrator.phase, .listening)
        XCTAssertEqual(harness.cancelCount, 1)
        XCTAssertEqual(harness.startCount, 2)
        XCTAssertEqual(
            harness.events,
            [.listeningStarted(.accessibility), .cancelled, .listeningStarted(.accessibility)]
        )
    }
}
