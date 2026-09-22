import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopSettingsQueueTests: XCTestCase {
    /// Apply A, Record, Apply B in UI order, with Record's own task scheduled
    /// only after B has been applied: the read still holds A.
    func testReadBetweenChanges_keepsItsPlaceWhenItsConsumerRunsAfterALaterChange() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let scheduler = SettingsGate()
        queue.submit { await settings.apply("A") }
        let snapshot = queue.read { await settings.value }
        let recording = Task { () -> String in
            let value = await snapshot.value
            await scheduler.wait()
            return value
        }
        queue.submit { await settings.apply("B") }
        await queue.drain()
        let applied = await settings.value
        XCTAssertEqual(applied, "B")
        await scheduler.open()
        let recorded = await recording.value
        XCTAssertEqual(recorded, "A")
    }

    /// Why an event must read through the queue: under the same legal schedule,
    /// waiting only for earlier work and reading later lets B reach the event.
    func testBarrierAlone_letsALaterChangeReachAReaderScheduledAfterIt() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let scheduler = SettingsGate()
        queue.submit { await settings.apply("A") }
        let earlier = queue.current
        let recording = Task { () -> String in
            await earlier?.value
            await scheduler.wait()
            return await settings.value
        }
        queue.submit { await settings.apply("B") }
        await queue.drain()
        await scheduler.open()
        let recorded = await recording.value
        XCTAssertEqual(recorded, "B")
    }

    /// An Apply queued before Record is used even while it is still saving.
    func testReadAfterSlowChange_waitsForIt() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let saving = SettingsGate()
        queue.submit {
            await saving.wait()
            await settings.apply("A")
        }
        let snapshot = queue.read { await settings.value }
        let early = Task { await snapshot.value }
        try? await Task.sleep(for: .milliseconds(50))
        let applied = await settings.history
        XCTAssertEqual(applied, [])
        await saving.open()
        let value = await early.value
        XCTAssertEqual(value, "A")
    }

    /// A later change waits for an earlier read to finish, and never for work
    /// its consumer does afterwards.
    func testLaterChange_waitsOnlyForTheReadItself() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let reading = SettingsGate()
        let consumer = SettingsGate()
        queue.submit { await settings.apply("A") }
        let snapshot = queue.read { () -> String in
            await reading.wait()
            return await settings.value
        }
        let recording = Task { () -> String in
            let value = await snapshot.value
            await consumer.wait()
            return value
        }
        queue.submit { await settings.apply("B") }
        try? await Task.sleep(for: .milliseconds(50))
        let heldByRead = await settings.value
        XCTAssertEqual(heldByRead, "A")
        await reading.open()
        await queue.drain()
        let afterRead = await settings.value
        XCTAssertEqual(afterRead, "B", "A consumer still holding its value must not block later settings")
        await consumer.open()
        let recorded = await recording.value
        XCTAssertEqual(recorded, "A")
    }

    func testSubmissions_runOneAtATimeInOrder() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let first = SettingsGate()
        queue.submit {
            await first.wait()
            await settings.apply("first")
        }
        queue.submit { await settings.apply("second") }
        try? await Task.sleep(for: .milliseconds(50))
        let early = await settings.history
        XCTAssertEqual(early, [])
        await first.open()
        await queue.drain()
        let history = await settings.history
        XCTAssertEqual(history, ["first", "second"])
    }
}

private actor SettingsProbe {
    private(set) var value = ""
    private(set) var history: [String] = []

    func apply(_ value: String) {
        self.value = value
        history.append(value)
    }
}

/// Holds callers until opened, like a scheduler delaying their tasks.
private actor SettingsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
