import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopTranscriptCopyDispatcherTests: XCTestCase {
    func testDelayedFirstCopy_cannotReplaceTheLatestClickedSnapshot() async {
        let scheduler = HeldCopyTasks()
        let clipboard = ClipboardProbe()
        let copies = DesktopTranscriptCopyDispatcher(launch: scheduler.enqueue) { text, variant in
            await clipboard.write(text, variant: variant)
        }
        copies.submit("Visible A", variant: .original)
        copies.submit("Visible B", variant: .processed)
        // Independent Tasks can enter the same actor in reverse order. The
        // production Copy boundary must keep B final under this legal schedule.
        await scheduler.runInReverseOrder()
        let value = await clipboard.text
        let variant = await clipboard.variant
        XCTAssertEqual(value, "Visible B")
        XCTAssertEqual(variant, .processed)
    }

    func testCopyBurstDuringWrite_keepsOneWorkerAndTheLatestSnapshot() async {
        let scheduler = HeldCopyTasks()
        let clipboard = ClipboardProbe()
        let started = expectation(description: "First clipboard write entered")
        let gate = CopyWriteGate()
        let copies = DesktopTranscriptCopyDispatcher(launch: scheduler.enqueue) { text, variant in
            if text == "A" { await gate.pause { started.fulfill() } }
            await clipboard.write(text, variant: variant)
        }
        copies.submit("A", variant: .original)
        let drain = Task { await scheduler.runInReverseOrder() }
        await fulfillment(of: [started], timeout: 2)
        for index in 0..<1_000 { copies.submit("B-\(index)", variant: .processed) }
        XCTAssertEqual(scheduler.launchCount, 1)
        await gate.resume()
        await drain.value
        let values = await clipboard.values
        XCTAssertEqual(values, ["A", "B-999"])
        copies.submit("C", variant: nil)
        await scheduler.runInReverseOrder()
        let final = await clipboard.text
        XCTAssertEqual(final, "C")
        XCTAssertEqual(scheduler.launchCount, 2)
    }

    func testSelectionAndCopy_haveIndependentLatestPendingValues() async {
        let scheduler = HeldCopyTasks()
        let clipboard = ClipboardProbe()
        let selection = ClipboardProbe()
        let copies = DesktopTranscriptCopyDispatcher(launch: scheduler.enqueue) { text, variant in
            await clipboard.write(text, variant: variant)
        }
        let selections = DesktopEventDispatcher<String>(launch: scheduler.enqueue) { identifier in
            await selection.write(identifier, variant: nil)
        }
        selections.submit("Selected A")
        copies.submit("Copied A", variant: .original)
        selections.submit("Selected B")
        copies.submit("Copied B", variant: .processed)
        await scheduler.runInReverseOrder()
        let shown = await selection.text
        let copied = await clipboard.text
        XCTAssertEqual(shown, "Selected B")
        XCTAssertEqual(copied, "Copied B")
        XCTAssertEqual(scheduler.launchCount, 2, "Copy must not consume a queued selection or version change")
    }
}

private actor CopyWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause(entered: () -> Void) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor ClipboardProbe {
    private(set) var text = ""
    private(set) var variant: DesktopTranscriptVariant?
    private(set) var values: [String] = []
    func write(_ text: String, variant: DesktopTranscriptVariant?) {
        self.text = text
        self.variant = variant
        values.append(text)
    }
}

private final class HeldCopyTasks: @unchecked Sendable {
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
