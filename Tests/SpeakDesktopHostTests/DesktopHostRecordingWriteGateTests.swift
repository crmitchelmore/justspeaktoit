import Foundation
import XCTest
@testable import SpeakDesktopHost

/// Thread-safe one-way-release latch replacing a former `NSConditionLock`
/// gate in `DesktopHostOwnedRecordingTests.swift`. Uses `NSCondition` only,
/// avoiding the Windows swift-corelibs-foundation defect where
/// `unlock(withCondition:)` leaves the owner sentinel non-nil, so lock reuse
/// treats it as "still held" and falls onto an unbounded `Date.distantFuture`
/// wait whose Windows timeout conversion overflows a 32-bit value and traps.
/// That original scenario is a SINGLE serial delivery queue reusing this gate
/// sequentially across two `beforePCM` deliveries, not concurrently; the
/// concurrent-pass test below is additional latch coverage for this
/// replacement gate's own correctness, not a restatement of the production
/// delivery path. Production is unchanged; only this synthetic test gate is
/// replaced. `internal` (not `private`) because it is also consumed from
/// `DesktopHostOwnedRecordingTests.swift` in this same test target.
final class RecordingWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var passes = 0

    /// Count of `pass()` calls started so far; mirrors the former `entered` flag.
    var enteredCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return passes
    }

    /// Blocks synchronously (required by the non-async `beforePCM` hook) until
    /// `release()` is observed, bounded by `timeout`. Safe for concurrent callers.
    func pass(timeout: TimeInterval = 30) throws {
        condition.lock()
        passes += 1
        defer { condition.unlock() }
        guard !released else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !released {
            let signaled = condition.wait(until: deadline)
            // Recheck the release predicate regardless of `wait(until:)`'s own
            // return value: a `broadcast()` from `release()` can race with the
            // deadline expiring, so a `false` (timed-out) result must not be
            // reported as a real timeout if `released` was actually observed
            // once control returns here.
            if released { break }
            if !signaled {
                throw DesktopHostError(message: "Synthetic writer gate timed out.")
            }
        }
    }

    /// Idempotent and permanent: every waiting and future `pass()` call returns immediately.
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Minimal cross-thread completion flag for the gate tests below. Avoids
/// `XCTestExpectation`/`XCTWaiter`: fulfilling from a raw background `Thread`
/// crashes swift-corelibs-xctest's waiter on Linux (reproduced in an earlier
/// draft of these tests; see the Round29 historical log in session evidence).
/// This file's own tests use a plain condition/poll pattern instead, matching
/// `RecordingGate`'s style in `DesktopHostOwnedRecordingTests.swift` -- no
/// claim is made here about the safety of unrelated `XCTWaiter` usages
/// elsewhere in the repo beyond this file's own tests.
private final class CompletionLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var done = false
    private var capturedError: Error?

    var isSet: Bool {
        condition.lock()
        defer { condition.unlock() }
        return done
    }

    /// Records the background thread's outcome (success or thrown error)
    /// under the same lock used for `wait`, instead of discarding it via
    /// `try?` and marking completion regardless of success.
    func complete(with result: Result<Void, Error>) {
        condition.lock()
        if case .failure(let error) = result {
            capturedError = error
        }
        done = true
        condition.broadcast()
        condition.unlock()
    }

    /// Waits up to `timeout` for `complete(with:)`, then returns the captured
    /// result so the calling test can assert success explicitly rather than
    /// merely observing that the thread returned.
    @discardableResult
    func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !done {
            if !condition.wait(until: deadline) && !done {
                return nil
            }
        }
        return capturedError.map(Result<Void, Error>.failure) ?? .success(())
    }
}

/// Bounded poll for a predicate that changes on another thread, used to
/// establish an entry handshake (wait for `enteredCount == 1`/`== 2`) before
/// making pre-release assertions, instead of a fixed `Thread.sleep` that only
/// provides a weak, flaky signal that a caller has actually entered `pass()`.
private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline { return predicate() }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}

final class DesktopHostRecordingWriteGateTests: XCTestCase {
    func testRecordingWriteGateBlocksUntilReleased() throws {
        let gate = RecordingWriteGate()
        let returned = CompletionLatch()
        defer { gate.release() } // bounded retirement even on an assertion failure below
        Thread {
            returned.complete(with: Result { try gate.pass(timeout: 5) })
        }.start()
        XCTAssertTrue(
            waitUntil { gate.enteredCount == 1 },
            "pass() must have been entered before asserting it has not yet returned"
        )
        XCTAssertFalse(returned.isSet, "pass() must not return before release() is called")
        gate.release()
        guard let result = returned.wait(timeout: 5) else {
            return XCTFail("pass() must return once release() has been called")
        }
        if case .failure(let error) = result {
            XCTFail("pass() must succeed once released, got \(error)")
        }
    }

    func testRecordingWriteGateReleaseIsIdempotentAndLatchedForFuturePasses() throws {
        let gate = RecordingWriteGate()
        gate.release()
        gate.release() // idempotent: must not hang or throw on a second call
        try gate.pass(timeout: 1) // already released: must return immediately
        XCTAssertEqual(gate.enteredCount, 1)
        try gate.pass(timeout: 1) // every future pass() after release also returns immediately
        XCTAssertEqual(gate.enteredCount, 2)
    }

    func testRecordingWriteGateThrowsOnTimeoutWhenNeverReleased() {
        let gate = RecordingWriteGate()
        defer { gate.release() } // retire the gate's own internal state even though no thread is blocked here
        // Short injected test-only deadline; the real call site always uses
        // the 30-second default.
        XCTAssertThrowsError(try gate.pass(timeout: 0.05)) { error in
            guard let hostError = error as? DesktopHostError else {
                return XCTFail("Expected DesktopHostError, got \(error)")
            }
            XCTAssertEqual(hostError.message, "Synthetic writer gate timed out.")
        }
    }

    func testRecordingWriteGateSupportsConcurrentPassesBeforeRelease() throws {
        // Additional latch coverage for this gate's own concurrency
        // correctness. The production `DesktopPressCapturePCMRelay` delivery
        // path that originally motivated this gate's replacement reuses a
        // SINGLE serial delivery queue -- its two `beforePCM` deliveries pass
        // through the gate sequentially, not concurrently -- so this test
        // does not restate that original crash path; it verifies the new
        // gate also behaves correctly for independent concurrent callers.
        let gate = RecordingWriteGate()
        let firstReturned = CompletionLatch()
        let secondReturned = CompletionLatch()
        defer { gate.release() } // bounded retirement even on an assertion failure below
        Thread {
            firstReturned.complete(with: Result { try gate.pass(timeout: 5) })
        }.start()
        Thread {
            secondReturned.complete(with: Result { try gate.pass(timeout: 5) })
        }.start()
        XCTAssertTrue(
            waitUntil { gate.enteredCount == 2 },
            "both pass() calls must have been entered before release() is called"
        )
        gate.release()
        guard let firstResult = firstReturned.wait(timeout: 5) else {
            return XCTFail("first pass() must return once release() has been called")
        }
        guard let secondResult = secondReturned.wait(timeout: 5) else {
            return XCTFail("second pass() must return once release() has been called")
        }
        if case .failure(let error) = firstResult {
            XCTFail("first pass() must succeed once released, got \(error)")
        }
        if case .failure(let error) = secondResult {
            XCTFail("second pass() must succeed once released, got \(error)")
        }
        XCTAssertEqual(gate.enteredCount, 2)
    }
}
