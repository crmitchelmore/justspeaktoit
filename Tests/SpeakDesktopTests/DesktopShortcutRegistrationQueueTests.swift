import Foundation
@testable import SpeakDesktop
import XCTest

final class DesktopShortcutRegistrationQueueTests: XCTestCase {
    func testRejectedLateStartupCleansBeforeTheFollowingRegistration() async {
        let queue = DesktopShortcutRegistrationQueue(label: "test.late-shortcut")
        let lifetime = DesktopShortcutListenerLifetime()
        let log = ShortcutRegistrationLog()
        let gate = ShortcutRegistrationGate()
        let entered = expectation(description: "registration entered")
        let drained = expectation(description: "following registration completed")
        defer { gate.release() }
        XCTAssertTrue(lifetime.begin())
        queue.submit {
            gate.wait { entered.fulfill() }
            XCTAssertFalse(lifetime.finish { queue.clean { log.append("cleanup") } })
            log.append("old registration returned")
        }
        await fulfillment(of: [entered], timeout: 10)
        lifetime.stop()
        queue.submit {
            log.append("new registration")
            drained.fulfill()
        }
        gate.release()
        await fulfillment(of: [drained], timeout: 10)
        XCTAssertEqual(log.values, ["cleanup", "old registration returned", "new registration"])
    }

    func testRegisteredCleanupRunsBeforeReplacementAndExactlyOnce() async {
        let queue = DesktopShortcutRegistrationQueue(label: "test.registered-shortcut")
        let lifetime = DesktopShortcutListenerLifetime()
        let log = ShortcutRegistrationLog()
        let registered = expectation(description: "registered")
        let drained = expectation(description: "replacement completed")
        XCTAssertTrue(lifetime.begin())
        queue.submit {
            XCTAssertTrue(lifetime.finish { queue.clean { log.append("cleanup") } })
            registered.fulfill()
        }
        await fulfillment(of: [registered], timeout: 10)
        lifetime.stop()
        lifetime.stop()
        queue.submit {
            log.append("replacement")
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 10)
        XCTAssertEqual(log.values, ["cleanup", "replacement"])
        XCTAssertFalse(lifetime.acceptsCallbacks)
    }

    func testStoppedQueuedStartupDoesNotOpenOrPublish() async {
        let queue = DesktopShortcutRegistrationQueue(label: "test.stopped-shortcut")
        let lifetime = DesktopShortcutListenerLifetime()
        let gate = ShortcutRegistrationGate()
        let entered = expectation(description: "worker occupied")
        let drained = expectation(description: "queued startup retired")
        defer { gate.release() }
        queue.submit { gate.wait { entered.fulfill() } }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertTrue(lifetime.begin())
        queue.submit {
            if lifetime.acceptsCallbacks { XCTFail("Stopped startup attempted native registration") }
            XCTAssertFalse(lifetime.publish { XCTFail("Stopped startup published") })
            drained.fulfill()
        }
        lifetime.stop()
        gate.release()
        await fulfillment(of: [drained], timeout: 10)
    }
}

private final class ShortcutRegistrationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
}

private final class ShortcutRegistrationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait(_ entered: () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        entered()
        let deadline = Date().addingTimeInterval(15)
        while !released {
            let signaled = condition.wait(until: deadline)
            if !released, !signaled { XCTFail("Shortcut registration gate timed out"); return }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
