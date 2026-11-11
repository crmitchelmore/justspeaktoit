import Foundation
@testable import SpeakCore
import XCTest

/// The run-owned watchdog handle: arm/retire keyed by run, and no stale tick
/// acting on a replacement run.
@MainActor
final class CaptureWatchdogHandleTests: XCTestCase {
    private let longAgo = Date(timeIntervalSinceNow: -120)

    func testRetireDuringStartup_cancelsTheTickBeforeItEvaluates() async {
        let ticks = ManualTicks()
        let handle = CaptureWatchdogHandle(sleep: ticks.sleep)
        var trips: [CaptureWatchdogTrip] = []
        let run = UUID()
        handle.arm(run: run, startedAt: longAgo, isLive: { true }, onTrip: { trip, _ in trips.append(trip) })
        await ticks.waitForSleepers(1)

        handle.retire()
        await ticks.releaseAll()
        await settle()

        XCTAssertTrue(trips.isEmpty, "a retired startup must never trip")
        XCTAssertNil(handle.runID)
        XCTAssertNil(handle.elapsedSeconds(for: run))
    }

    func testDelayedTickFromRetiredRun_cannotActOnTheRunThatReplacedIt() async {
        let ticks = ManualTicks()
        let handle = CaptureWatchdogHandle(sleep: ticks.sleep)
        var trips: [UUID] = []
        let first = UUID()
        let second = UUID()
        // Run A is past its start deadline, so its tick would trip if it woke as A.
        handle.arm(run: first, startedAt: longAgo, isLive: { true }, onTrip: { _, run in trips.append(run) })
        await ticks.waitForSleepers(1)
        handle.arm(run: second, startedAt: Date(), isLive: { true }, onTrip: { _, run in trips.append(run) })
        await ticks.waitForSleepers(2)

        // Both sleeps return together; A's tick wakes after B was armed.
        await ticks.releaseAll()
        await settle()

        XCTAssertTrue(trips.isEmpty)
        XCTAssertTrue(handle.owns(second))
        XCTAssertFalse(handle.owns(first))
        handle.note(.sessionStarted, run: first)
        handle.noteInputObserved(run: first)
        XCTAssertEqual(handle.monitor, CaptureWatchdogMonitor(), "A's late reports must not touch B's bounds")
        handle.retire()
    }

    func testOwnerNoLongerLive_isNeverEvaluated() async {
        let ticks = ManualTicks()
        let handle = CaptureWatchdogHandle(sleep: ticks.sleep)
        var trips = 0
        handle.arm(run: UUID(), startedAt: longAgo, isLive: { false }, onTrip: { _, _ in trips += 1 })
        await ticks.waitForSleepers(1)
        await ticks.releaseAll()
        await ticks.waitForSleepers(1)

        XCTAssertEqual(trips, 0)
        handle.retire()
        await ticks.releaseAll()
    }

    func testWarningKeepsTicking_thenTheCapEndsTheTick() async {
        let ticks = ManualTicks()
        var clock = Date(timeIntervalSince1970: 0)
        let handle = CaptureWatchdogHandle(sleep: ticks.sleep, now: { clock })
        var trips: [CaptureWatchdogTrip] = []
        let run = UUID()
        handle.arm(run: run, startedAt: clock, isLive: { true }, onTrip: { trip, _ in trips.append(trip) })
        handle.monitor = CaptureWatchdogMonitor(CaptureWatchdogBudget(
            startDeadline: 60, firstInputDeadline: 10, maximumDuration: 100, maximumDurationWarningLead: 10
        ))
        handle.note(.sessionStarted, run: run)

        clock = Date(timeIntervalSince1970: 95)
        await ticks.waitForSleepers(1)
        await ticks.releaseAll()
        await ticks.waitForSleepers(1)
        await settle()
        XCTAssertEqual(trips, [.maximumDurationWarning])

        clock = Date(timeIntervalSince1970: 100)
        await ticks.releaseAll()
        await settle()
        XCTAssertEqual(trips, [.maximumDurationWarning, .maximumDuration])
        XCTAssertEqual(ticks.sleepers, 0, "a terminal trip ends the tick")
        handle.retire()
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

/// A tick clock the test advances by hand. A sleeper is resumed only by
/// `releaseAll()`, never by cancellation, so a retired tick that wakes late is
/// exercised rather than skipped.
@MainActor
private final class ManualTicks {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var sleepers: Int { waiters.count }

    nonisolated var sleep: CaptureWatchdogHandle.Sleep {
        { [weak self] _ in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let self else { return continuation.resume() }
                    self.waiters.append(continuation)
                }
            }
        }
    }

    func waitForSleepers(_ count: Int) async {
        for _ in 0..<1000 where waiters.count < count {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(waiters.count, count, "tick never slept")
    }

    func releaseAll() async {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
        for _ in 0..<10 { await Task.yield() }
    }
}
