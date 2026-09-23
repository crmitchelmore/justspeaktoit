import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopSettingsQueueTests: XCTestCase {
    /// Apply A, Record, Apply B in UI order, with Record's own task scheduled
    /// only after B has been applied: the read still holds A, and the queue
    /// drains while that consumer is still held.
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
        let savingEntered = SettingsGate()
        let saving = SettingsGate()
        queue.submit {
            await savingEntered.open()
            await saving.wait()
            await settings.apply("A")
        }
        let snapshot = queue.read { () -> String in
            await settings.note("read")
            return await settings.value
        }
        // Apply A is held mid-save; the read is queued behind it.
        await savingEntered.wait()
        let whileSaving = await settings.history
        XCTAssertEqual(whileSaving, [])
        await saving.open()
        let value = await snapshot.value
        XCTAssertEqual(value, "A")
        let history = await settings.history
        XCTAssertEqual(history, ["A", "read"])
    }

    /// A later change waits for an earlier read to finish, and never for work
    /// its consumer does afterwards.
    func testLaterChange_waitsOnlyForTheReadItself() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let readEntered = SettingsGate()
        let reading = SettingsGate()
        let consumer = SettingsGate()
        queue.submit { await settings.apply("A") }
        let snapshot = queue.read { () -> String in
            await readEntered.open()
            await reading.wait()
            return await settings.value
        }
        let recording = Task { () -> String in
            let value = await snapshot.value
            await consumer.wait()
            return value
        }
        queue.submit { await settings.apply("B") }
        // The read has started, so A has finished; B is queued behind the held read.
        await readEntered.wait()
        let whileReading = await settings.history
        XCTAssertEqual(whileReading, ["A"])
        await reading.open()
        // The consumer still holds its value, yet the queue drains.
        await queue.drain()
        let afterRead = await settings.history
        XCTAssertEqual(afterRead, ["A", "B"], "A consumer still holding its value must not block later settings")
        await consumer.open()
        let recorded = await recording.value
        XCTAssertEqual(recorded, "A")
    }

    func testSubmissions_runOneAtATimeInOrder() async {
        let queue = DesktopSettingsQueue()
        let settings = SettingsProbe()
        let firstEntered = SettingsGate()
        let first = SettingsGate()
        queue.submit {
            await firstEntered.open()
            await first.wait()
            await settings.apply("first")
        }
        queue.submit { await settings.apply("second") }
        // The first submission is running and held; the second must not start.
        await firstEntered.wait()
        let whileFirstRuns = await settings.history
        XCTAssertEqual(whileFirstRuns, [])
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

    func note(_ event: String) { history.append(event) }
}

/// Holds callers until opened, like a scheduler delaying their tasks. Opening
/// one also serves as a signal that a held operation has been reached.
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
