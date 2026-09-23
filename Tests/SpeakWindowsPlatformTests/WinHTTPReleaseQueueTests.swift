import Foundation
import XCTest
@testable import SpeakWindowsPlatform

final class WinHTTPReleaseQueueTests: XCTestCase {
    func testSuccessfulReleaseIsNotRetainedOrRetried() {
        let queue = WinHTTPReleaseQueue(limit: 1, initialDelay: 0.01, maximumDelay: 0.02)
        let release = ScriptedRelease(outcomes: [true])
        queue.release { release.attempt() }
        XCTAssertTrue(eventually { release.attempts == 1 })
        XCTAssertEqual(queue.outstanding, 0)
        XCTAssertTrue(queue.admit())
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(release.attempts, 1)
    }

    func testFailedReleaseStaysOwnedAndIsRetriedUntilNativeDestroySucceeds() {
        let queue = WinHTTPReleaseQueue(limit: 4, initialDelay: 0.01, maximumDelay: 0.02)
        let release = ScriptedRelease(outcomes: [false, false, true])
        queue.release { release.attempt() }
        XCTAssertTrue(eventually { release.attempts >= 1 && queue.outstanding == 1 })
        XCTAssertTrue(eventually { release.attempts == 3 && queue.outstanding == 0 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(release.attempts, 3, "a freed context is never destroyed twice")
    }

    func testOutstandingFailuresRefuseNewConnectionsUntilARetrySucceeds() {
        let queue = WinHTTPReleaseQueue(limit: 1, initialDelay: 60, maximumDelay: 60)
        let release = ScriptedRelease(outcomes: [false, true])
        queue.release { release.attempt() }
        XCTAssertTrue(eventually { queue.outstanding == 1 })
        XCTAssertFalse(queue.admit(), "the bound refuses more native state while a release is owned")
        XCTAssertTrue(eventually { release.attempts == 2 && queue.outstanding == 0 },
                      "admission retries owned releases without waiting for the backoff")
        XCTAssertTrue(queue.admit())
    }

    func testConcurrentAdmissionsNeverOverlapAttemptsForOneRelease() {
        let queue = WinHTTPReleaseQueue(limit: 8, initialDelay: 60, maximumDelay: 60)
        let release = ScriptedRelease(outcomes: [false] + Array(repeating: false, count: 64), delay: 0.002)
        queue.release { release.attempt() }
        XCTAssertTrue(eventually { queue.outstanding == 1 })
        DispatchQueue.concurrentPerform(iterations: 16) { _ in _ = queue.admit() }
        XCTAssertTrue(eventually { release.attempts >= 2 })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(release.maximumConcurrency, 1)
        XCTAssertEqual(queue.outstanding, 1, "a still-failing release remains owned")
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
    private let delay: TimeInterval
    private var active = 0
    private var count = 0
    private var peak = 0

    init(outcomes: [Bool], delay: TimeInterval = 0) {
        self.outcomes = outcomes
        self.delay = delay
    }

    var attempts: Int { lock.withLock { count } }
    var maximumConcurrency: Int { lock.withLock { peak } }

    func attempt() -> Bool {
        let outcome = lock.withLock { () -> Bool in
            count += 1
            active += 1
            peak = max(peak, active)
            return outcomes.isEmpty ? false : outcomes.removeFirst()
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { active -= 1 }
        return outcome
    }
}
