import Foundation
import SpeakDesktopSync
import XCTest

/// Shutdown of a desktop host's sync work: nothing new starts, what runs is
/// cancelled and awaited within a bound, and nothing reaches the window.
final class DesktopCloudSyncWorkTests: XCTestCase {
    func testStoppingRefusesNewWorkAndCancelsWhatRuns() async throws {
        let work = DesktopCloudSyncWork()
        let started = Latch()
        let pass = try XCTUnwrap(work.start {
            await started.open()
            await waitUntilCancelled()
        })
        await started.wait()

        let running = work.stop()
        let late = work.start { XCTFail("Work started after shutdown") }
        // No deadline passes: the drain ends because the cancelled work did.
        await DesktopCloudSyncWork.drain(running) { await waitUntilCancelled() }

        XCTAssertEqual(running.count, 1)
        XCTAssertNil(late)
        XCTAssertTrue(pass.isCancelled)
        XCTAssertEqual(work.runningCount, 0)
    }

    func testDrainingEndsAtItsDeadlineWhenWorkCannotBeAbandoned() async throws {
        let work = DesktopCloudSyncWork()
        let stuck = Latch()
        let deadline = Latch()
        work.start { await stuck.wait() }
        try await eventually { await stuck.waiterCount == 1 }
        let running = work.stop()

        let drained = Task { await DesktopCloudSyncWork.drain(running) { await deadline.wait() } }
        try await eventually { await deadline.waiterCount == 1 }
        await deadline.open()
        await drained.value

        let stillWaiting = await stuck.waiterCount
        XCTAssertEqual(stillWaiting, 1, "the drain returned at its deadline, not when the work ended")
        await stuck.open()
        for task in running {
            await task.value
        }
    }

    func testNothingReachesTheWindowOnceStopped() {
        let work = DesktopCloudSyncWork()
        XCTAssertEqual(work.ifRunning { "shown" }, "shown")

        _ = work.stop()

        XCTAssertTrue(work.isStopped)
        XCTAssertNil(work.ifRunning { "shown" })
    }

    func testFinishedWorkIsNoLongerOwned() async throws {
        let work = DesktopCloudSyncWork()
        let pass = try XCTUnwrap(work.start {})

        await pass.value

        XCTAssertEqual(work.runningCount, 0)
        XCTAssertTrue(work.stop().isEmpty)
    }
}

/// A one-shot signal a test opens by hand. Waiting on it ignores cancellation.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// Suspends until the current task is cancelled, as a pass waiting on a
/// cooperative request does.
func waitUntilCancelled() async {
    let cancelled = Latch()
    await withTaskCancellationHandler {
        await cancelled.wait()
    } onCancel: {
        Task { await cancelled.open() }
    }
}
