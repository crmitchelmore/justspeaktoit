import Foundation
import XCTest
@testable import SpeakWindowsPlatform

final class WinHTTPReleaseQueueTests: XCTestCase {
    /// Destruction runs here; `sync` returns once everything queued so far has run.
    private let releases = DispatchQueue(label: "WinHTTPReleaseQueueTests.release")
    /// Retry timers wait for `fire()` instead of wall-clock time.
    private let scheduler = ManualScheduler()

    func testSuccessfulReleaseIsNotRetainedOrRetried() {
        let queue = makeQueue(limit: 1)
        let release = ScriptedRelease(outcomes: [true])
        queue.release { release.attempt() }
        releases.sync {}
        XCTAssertEqual(release.attempts, 1)
        XCTAssertEqual(queue.outstanding, 0)
        XCTAssertTrue(queue.admit())
        releases.sync {}
        XCTAssertEqual(release.attempts, 1)
        XCTAssertEqual(scheduler.pending, 0)
    }

    func testFailedReleaseStaysOwnedAndIsRetriedUntilNativeDestroySucceeds() {
        // Production scheduling: real backoff timers on the queue's own release queue.
        let queue = WinHTTPReleaseQueue(limit: 4, initialDelay: 0.01, maximumDelay: 0.02)
        let release = ScriptedRelease(outcomes: [false, false, true])
        queue.release { release.attempt() }
        XCTAssertTrue(eventually { release.attempts == 3 && queue.outstanding == 0 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(release.attempts, 3, "a freed context is never destroyed twice")
    }

    func testOutstandingFailuresRefuseNewConnectionsUntilARetrySucceeds() {
        let queue = makeQueue(limit: 1)
        let release = ScriptedRelease(outcomes: [false, true])
        queue.release { release.attempt() }
        releases.sync {}
        XCTAssertEqual(queue.outstanding, 1)
        XCTAssertFalse(queue.admit(), "the bound refuses more native state while a release is owned")
        releases.sync {}
        XCTAssertEqual(release.attempts, 2, "admission retries owned releases without waiting for the backoff")
        XCTAssertEqual(queue.outstanding, 0)
        XCTAssertTrue(queue.admit())
    }

    func testConcurrentAdmissionsNeverOverlapAttemptsForOneRelease() {
        let queue = makeQueue(limit: 8)
        let release = ScriptedRelease(delay: 0.002)
        queue.release { release.attempt() }
        releases.sync {}
        DispatchQueue.concurrentPerform(iterations: 16) { _ in _ = queue.admit() }
        releases.sync {}
        XCTAssertEqual(release.attempts, 2, "concurrent admissions share one retry")
        XCTAssertEqual(release.maximumConcurrency, 1)
        XCTAssertEqual(queue.outstanding, 1, "a still-failing release remains owned")
    }

    func testReleaseCountsAgainstAdmissionBeforeItsFirstAttemptIsDispatched() {
        let queue = makeQueue(limit: 1)
        let release = ScriptedRelease(afterwards: true)
        releases.suspend()
        queue.release { release.attempt() }
        let owned = queue.outstanding
        let admitted = queue.admit()
        let attemptsBeforeDispatch = release.attempts
        releases.resume()
        XCTAssertEqual(owned, 1, "a queued release is counted before it runs")
        XCTAssertFalse(admitted)
        XCTAssertEqual(attemptsBeforeDispatch, 0)
        releases.sync {}
        XCTAssertEqual(release.attempts, 1)
        XCTAssertEqual(queue.outstanding, 0)
        XCTAssertTrue(queue.admit())
    }

    func testHeldDestructionBoundsASustainedCreateCloseBurstWithoutBlockingCallers() {
        let queue = makeQueue(limit: 4)
        let gate = Gate()
        let held = ScriptedRelease(outcomes: [false, true])
        let closed = ScriptedRelease(afterwards: true)
        queue.release { gate.pass(); return held.attempt() }
        XCTAssertTrue(gate.waitUntilReached())
        let admitted = Tally()
        let burst = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Each admitted connection creates native state, then closes and hands it over.
            for _ in 0..<10_000 where queue.admit() {
                admitted.increment()
                queue.release { closed.attempt() }
            }
            burst.signal()
        }
        XCTAssertEqual(burst.wait(timeout: .now() + 5), .success, "admission and release never wait for a destroy")
        XCTAssertEqual(admitted.value, 3, "only three more sockets join the held one")
        XCTAssertEqual(queue.outstanding, 4)
        XCTAssertEqual(closed.attempts, 0, "queued releases stay owned behind the held destruction")
        gate.open()
        releases.sync {}
        XCTAssertEqual(closed.attempts, 3, "each queued release runs exactly once")
        XCTAssertEqual(queue.outstanding, 1, "the held destruction failed and stays owned")
        XCTAssertTrue(queue.admit())
        releases.sync {}
        XCTAssertEqual(held.attempts, 2)
        XCTAssertEqual(queue.outstanding, 0)
    }

    func testConcurrentBurstIsBoundedByCallerConcurrencyAndReleasesEachSocketOnce() {
        let limit = 4
        let queue = makeQueue(limit: limit)
        let gate = Gate()
        let closed = ScriptedRelease(afterwards: true)
        queue.release { gate.pass(); return true }
        XCTAssertTrue(gate.waitUntilReached())
        let admitted = Tally()
        let workers = 8
        let burst = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                for _ in 0..<500 where queue.admit() {
                    admitted.increment()
                    queue.release { closed.attempt() }
                }
            }
            burst.signal()
        }
        XCTAssertEqual(burst.wait(timeout: .now() + 5), .success)
        // Admission and hand-over are separate calls, so callers admitted
        // concurrently may each hand over their socket after the limit is reached.
        XCTAssertGreaterThanOrEqual(queue.outstanding, limit)
        XCTAssertLessThanOrEqual(queue.outstanding, limit + workers - 1)
        XCTAssertEqual(queue.outstanding, admitted.value + 1)
        gate.open()
        releases.sync {}
        XCTAssertEqual(closed.attempts, admitted.value, "no release is dropped or repeated")
        XCTAssertEqual(queue.outstanding, 0)
    }

    func testAdmissionRetriesAreCoalescedWhileTheReleaseQueueIsBusy() {
        let queue = makeQueue()
        let failing = ScriptedRelease()
        queue.release { failing.attempt() }
        releases.sync {}
        XCTAssertEqual(scheduler.pending, 1)
        let gate = Gate()
        queue.release { gate.pass(); return true }
        XCTAssertTrue(gate.waitUntilReached())
        for _ in 0..<1_000 { _ = queue.admit() }
        gate.open()
        releases.sync {}
        XCTAssertEqual(failing.attempts, 2, "a busy queue runs one admission retry, not one per admission")
        XCTAssertEqual(scheduler.pending, 1, "the armed backoff timer is kept, not duplicated")
        XCTAssertEqual(queue.outstanding, 1, "a still-failing release stays owned")
        scheduler.fire()
        releases.sync {}
        XCTAssertEqual(failing.attempts, 3)
        XCTAssertEqual(scheduler.pending, 1)
    }

    func testFailedReleaseBacksOffOnOneTimerAndOnlyRunsOnTheReleaseQueue() {
        let key = DispatchSpecificKey<Void>()
        releases.setSpecific(key: key, value: ())
        let queue = makeQueue(initialDelay: 1, maximumDelay: 4)
        let release = ScriptedRelease(outcomes: [false, false, false, false, true])
        let elsewhere = Tally()
        queue.release {
            if DispatchQueue.getSpecific(key: key) == nil { elsewhere.increment() }
            return release.attempt()
        }
        releases.sync {}
        for _ in 0..<4 {
            XCTAssertEqual(scheduler.pending, 1)
            XCTAssertEqual(queue.outstanding, 1)
            scheduler.fire()
            releases.sync {}
        }
        XCTAssertEqual(release.attempts, 5)
        XCTAssertEqual(scheduler.delays, [1, 2, 4, 4])
        XCTAssertEqual(scheduler.pending, 0)
        XCTAssertEqual(queue.outstanding, 0)
        XCTAssertEqual(elsewhere.value, 0, "retries fired on another thread still destroy on the release queue")
    }

    private func makeQueue(
        limit: Int = 4, initialDelay: TimeInterval = 60, maximumDelay: TimeInterval = 60
    ) -> WinHTTPReleaseQueue {
        let scheduler = scheduler
        return WinHTTPReleaseQueue(
            limit: limit, initialDelay: initialDelay, maximumDelay: maximumDelay, queue: releases,
            schedule: { scheduler.schedule($0, $1) }
        )
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}

private final class ScriptedRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Bool]
    private let afterwards: Bool
    private let delay: TimeInterval
    private var active = 0
    private var count = 0
    private var peak = 0

    /// Returns each scripted outcome in turn, then `afterwards` for every later attempt.
    init(outcomes: [Bool] = [], afterwards: Bool = false, delay: TimeInterval = 0) {
        self.outcomes = outcomes
        self.afterwards = afterwards
        self.delay = delay
    }

    var attempts: Int { lock.withLock { count } }
    var maximumConcurrency: Int { lock.withLock { peak } }

    func attempt() -> Bool {
        let outcome = lock.withLock { () -> Bool in
            count += 1
            active += 1
            peak = max(peak, active)
            return outcomes.isEmpty ? afterwards : outcomes.removeFirst()
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { active -= 1 }
        return outcome
    }
}

/// Holds a native destroy on the release queue until the test opens it; later
/// passes go straight through.
private final class Gate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let opened = DispatchGroup()

    init() { opened.enter() }

    func pass() {
        reached.signal()
        opened.wait()
    }

    func waitUntilReached() -> Bool { reached.wait(timeout: .now() + 5) == .success }

    /// Call exactly once per gate.
    func open() { opened.leave() }
}

/// Keeps backoff timers until the test fires them, as if their delays had elapsed.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [@Sendable () -> Void] = []
    private var history: [TimeInterval] = []

    var pending: Int { lock.withLock { timers.count } }
    var delays: [TimeInterval] { lock.withLock { history } }

    func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            timers.append(work)
            history.append(delay)
        }
    }

    func fire() {
        let due = lock.withLock { () -> [@Sendable () -> Void] in
            defer { timers.removeAll() }
            return timers
        }
        due.forEach { $0() }
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
