import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopEventDispatcherTests: XCTestCase {
    func testDelayedFirstNativeSelection_cannotOverwriteNewerSelection() async {
        let scheduler = HeldDesktopTasks()
        let selection = HistorySelectionProbe()
        let dispatcher = DesktopEventDispatcher<String>(launch: scheduler.enqueue) { identifier in
            await selection.select(identifier)
        }
        dispatcher.submit("A")
        dispatcher.submit("B")
        // An unstructured Task may enter the controller after a later Task.
        // This explicitly schedules B before delayed A without clock sleeps.
        await scheduler.runInReverseOrder()
        let shown = await selection.current
        XCTAssertEqual(shown, "B", "The latest native selection must own the displayed transcript")
    }

    func testInFlightSelection_coalescesBurstAndRelaunchesAfterDrain() async {
        let scheduler = HeldDesktopTasks()
        let started = expectation(description: "First selection entered actor")
        let release = HistoryEventGate()
        let selection = HistorySelectionProbe()
        let dispatcher = DesktopEventDispatcher<String>(launch: scheduler.enqueue) { identifier in
            if identifier == "A" {
                await release.pause { started.fulfill() }
            }
            await selection.select(identifier)
        }
        dispatcher.submit("A")
        let drain = Task { await scheduler.runInReverseOrder() }
        await fulfillment(of: [started], timeout: 2)
        for index in 0..<1_000 { dispatcher.submit("B-\(index)") }
        XCTAssertEqual(
            scheduler.launchCount, 1, "A selection burst must retain one worker and one latest pending value"
        )
        await release.resume()
        await drain.value
        let values = await selection.values
        XCTAssertEqual(values, ["A", "B-999"])
        dispatcher.submit("C")
        await scheduler.runInReverseOrder()
        let shown = await selection.current
        XCTAssertEqual(shown, "C")
        XCTAssertEqual(scheduler.launchCount, 2)
    }
}

private actor HistoryEventGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause(entered: () -> Void) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor HistorySelectionProbe {
    private(set) var current = ""
    private(set) var values: [String] = []
    func select(_ identifier: String) { current = identifier; values.append(identifier) }
}

private final class HeldDesktopTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () async -> Void] = []
    private var launches = 0
    var launchCount: Int { lock.withLock { launches } }
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock { launches += 1; operations.append(operation) }
    }
    func runInReverseOrder() async {
        let pending = lock.withLock { let pending = operations; operations.removeAll(); return pending }
        for operation in pending.reversed() { await operation() }
    }
}
