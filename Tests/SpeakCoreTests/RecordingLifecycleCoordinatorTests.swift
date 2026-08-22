import XCTest

@testable import SpeakCore

/// The run-identity state machine behind cancellable recording startup
/// (issue #701): a stop during `starting` retires the pending run, the
/// retired run unwinds its own allocations, waiting stops settle only after
/// that unwind, and a stale run can neither publish state nor disturb a
/// replacement run.
@MainActor
final class RecordingLifecycleCoordinatorTests: XCTestCase {
    func testHappyPath_startActivateStopReturnsToIdle() {
        let coordinator = RecordingLifecycleCoordinator()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isActive)

        let runID = coordinator.beginStart()
        XCTAssertNotNil(runID)
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertTrue(coordinator.isActive, "starting must read as an active operation")

        XCTAssertTrue(coordinator.activate(runID!))
        XCTAssertEqual(coordinator.state, .recording)

        XCTAssertTrue(coordinator.beginStopping())
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertFalse(coordinator.isActive)
        coordinator.finishStopping()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDoubleStart_isRefusedWhileAnyRunIsInFlight() {
        let coordinator = RecordingLifecycleCoordinator()
        let first = coordinator.beginStart()
        XCTAssertNotNil(first)
        XCTAssertNil(coordinator.beginStart(), "starting must refuse a second run")

        XCTAssertTrue(coordinator.activate(first!))
        XCTAssertNil(coordinator.beginStart(), "recording must refuse a new run")
    }

    func testStopDuringStarting_retiresTheRunAndTheRunCannotActivate() {
        let coordinator = RecordingLifecycleCoordinator()
        let runID = coordinator.beginStart()!

        // The user stopped while startup was suspended (e.g. Keychain load).
        coordinator.retireStartRun()

        XCTAssertFalse(coordinator.isCurrentStartRun(runID))
        XCTAssertFalse(
            coordinator.activate(runID),
            "a retired run must not publish recording state"
        )
        XCTAssertEqual(coordinator.state, .starting, "the retired run still owns the unwind")

        coordinator.finishStartUnwind()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testAwaitStartSettled_returnsOnlyAfterTheRetiredRunUnwound() async {
        let coordinator = RecordingLifecycleCoordinator()
        let runID = coordinator.beginStart()!
        coordinator.retireStartRun()

        let settled = XCTestExpectation(description: "stop settled")
        let waiter = Task { @MainActor in
            await coordinator.awaitStartSettled()
            XCTAssertNotEqual(coordinator.state, .starting)
            settled.fulfill()
        }
        // Let the waiter suspend before the run unwinds.
        await Task.yield()
        XCTAssertFalse(coordinator.isCurrentStartRun(runID))

        coordinator.finishStartUnwind()
        await fulfillment(of: [settled], timeout: 2)
        _ = await waiter.value
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testAwaitStartSettled_resolvesImmediatelyOutsideStarting() async {
        let coordinator = RecordingLifecycleCoordinator()
        await coordinator.awaitStartSettled()

        let runID = coordinator.beginStart()!
        XCTAssertTrue(coordinator.activate(runID))
        await coordinator.awaitStartSettled()
        XCTAssertEqual(coordinator.state, .recording)
    }

    func testRapidStartStopStart_staleRunCannotTouchTheReplacementRun() {
        let coordinator = RecordingLifecycleCoordinator()
        let first = coordinator.beginStart()!
        coordinator.retireStartRun()

        // No replacement can begin until the retired run has unwound, so a
        // stale run never coexists with a newer one it could tear down.
        XCTAssertNil(coordinator.beginStart())
        coordinator.finishStartUnwind()

        let second = coordinator.beginStart()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)

        // The stale identity has no power over the replacement run.
        XCTAssertFalse(coordinator.isCurrentStartRun(first))
        XCTAssertFalse(coordinator.activate(first))
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertTrue(coordinator.isCurrentStartRun(second!))
        XCTAssertTrue(coordinator.activate(second!))
        XCTAssertEqual(coordinator.state, .recording)
    }

    func testStartupFailure_unwindSettlesWaitersAndFreesTheService() async {
        let coordinator = RecordingLifecycleCoordinator()
        _ = coordinator.beginStart()!

        let settled = XCTestExpectation(description: "settled after failure")
        let waiter = Task { @MainActor in
            await coordinator.awaitStartSettled()
            settled.fulfill()
        }
        await Task.yield()

        // The run's own failure path unwinds; the service is reusable after.
        coordinator.finishStartUnwind()
        await fulfillment(of: [settled], timeout: 2)
        _ = await waiter.value
        XCTAssertNotNil(coordinator.beginStart())
    }

    func testBeginStopping_refusedOutsideRecording() {
        let coordinator = RecordingLifecycleCoordinator()
        XCTAssertFalse(coordinator.beginStopping())

        _ = coordinator.beginStart()
        XCTAssertFalse(
            coordinator.beginStopping(),
            "a pending start is cancelled via retireStartRun, not stopped"
        )
    }
}
