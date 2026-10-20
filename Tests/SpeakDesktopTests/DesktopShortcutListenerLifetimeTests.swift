import Foundation
@testable import SpeakDesktop
import XCTest

final class DesktopShortcutListenerLifetimeTests: XCTestCase {
    func testStopBeforeStart_PermanentlyRefusesAdmissionAndPublication() {
        let lifetime = DesktopShortcutListenerLifetime()
        lifetime.stop()
        lifetime.stop()
        XCTAssertFalse(lifetime.begin())
        XCTAssertFalse(lifetime.acceptsCallbacks)
        XCTAssertFalse(lifetime.publish { XCTFail("A stopped listener published") })
    }

    func testActiveRegistration_StopsExactlyOnceAndNeverRestarts() {
        let lifetime = DesktopShortcutListenerLifetime()
        let cleaned = ListenerCleanupCounter()
        XCTAssertFalse(lifetime.acceptsCallbacks)
        XCTAssertFalse(lifetime.publish { XCTFail("An unstarted listener published") })
        XCTAssertTrue(lifetime.begin())
        XCTAssertFalse(lifetime.begin())
        XCTAssertTrue(lifetime.acceptsCallbacks)
        XCTAssertFalse(lifetime.publish { XCTFail("An unfinished registration published") })
        XCTAssertTrue(lifetime.finish { cleaned.increment() })
        XCTAssertTrue(lifetime.publish {})
        XCTAssertTrue(lifetime.acceptsCallbacks)
        lifetime.stop()
        lifetime.stop()
        XCTAssertEqual(cleaned.value, 1)
        XCTAssertFalse(lifetime.begin())
        XCTAssertFalse(lifetime.acceptsCallbacks)
        XCTAssertFalse(lifetime.publish { XCTFail("A closed listener republished") })
    }

    func testHeldStartup_StopReturnsBeforeNativeCompletionAndCleansLateSuccess() async {
        let lifetime = DesktopShortcutListenerLifetime()
        let cleaned = ListenerCleanupCounter()
        let entered = expectation(description: "native registration entered")
        let gate = ListenerStartupGate()
        defer { gate.release() }
        XCTAssertTrue(lifetime.begin())
        let worker = Task.detached {
            gate.wait { entered.fulfill() }
            return lifetime.finish { cleaned.increment() }
        }
        await fulfillment(of: [entered], timeout: 10)
        lifetime.stop()
        XCTAssertTrue(gate.isBlocked, "Stop must not wait for an uncooperative native registration")
        XCTAssertFalse(lifetime.acceptsCallbacks)
        XCTAssertEqual(cleaned.value, 0)
        XCTAssertFalse(lifetime.publish { XCTFail("Stopped startup published") })
        gate.release()
        let accepted = await worker.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(cleaned.value, 1)
        lifetime.stop()
        XCTAssertEqual(cleaned.value, 1)
    }

    func testFailedRegistration_PublishesItsHintButCannotAdmitCallbacks() {
        let lifetime = DesktopShortcutListenerLifetime()
        XCTAssertTrue(lifetime.begin())
        XCTAssertTrue(lifetime.finish(cleanup: nil))
        XCTAssertFalse(lifetime.acceptsCallbacks)
        XCTAssertTrue(lifetime.publish {})
        XCTAssertFalse(lifetime.begin())
        lifetime.stop()
        XCTAssertFalse(lifetime.publish { XCTFail("A closed failure republished") })
    }

    func testCleanup_RunsOutsideTheLockAfterCallbackAdmissionIsFenced() {
        let lifetime = DesktopShortcutListenerLifetime()
        let cleaned = ListenerCleanupCounter()
        XCTAssertTrue(lifetime.begin())
        XCTAssertTrue(lifetime.finish {
            XCTAssertFalse(lifetime.acceptsCallbacks)
            lifetime.stop()
            cleaned.increment()
        })
        lifetime.stop()
        XCTAssertEqual(cleaned.value, 1)
    }

    func testRacingCompletionAndStop_AlwaysCleansExactlyOnceWithoutLatePublication() async {
        for _ in 0..<64 {
            let lifetime = DesktopShortcutListenerLifetime()
            let cleaned = ListenerCleanupCounter()
            XCTAssertTrue(lifetime.begin())
            let completing = Task.detached { lifetime.finish { cleaned.increment() } }
            let stopping = Task.detached { lifetime.stop() }
            _ = await completing.value
            await stopping.value
            XCTAssertEqual(cleaned.value, 1)
            XCTAssertFalse(lifetime.acceptsCallbacks)
            XCTAssertFalse(lifetime.publish { XCTFail("Racing stop allowed publication") })
        }
    }
}

private final class ListenerCleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ListenerStartupGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    var isBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked && !released
    }

    func wait(_ entered: () -> Void) {
        condition.lock()
        blocked = true
        entered()
        while !released { condition.wait() }
        blocked = false
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
