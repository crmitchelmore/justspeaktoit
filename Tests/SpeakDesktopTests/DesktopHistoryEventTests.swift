import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopHistoryEventTests: XCTestCase {
    /// Why History clicks share one ordered lane: the previous wiring started
    /// one Task per click, and independent Tasks may enter the host in either
    /// order. Under this legal schedule audio starts after Stop, and Play on
    /// a newly selected row is refused because the row is not selected yet.
    func testIndependentClickTasks_canRestartAudioAfterStopAndDropANewRowsPlay() async {
        let scheduler = HeldHistoryTasks()
        let stopped = HistoryHostProbe(selected: "A")
        scheduler.enqueue { await stopped.perform(.playPause("A")) }
        scheduler.enqueue { await stopped.perform(.stop) }
        await scheduler.runInReverseOrder()
        let restarted = await stopped.audible
        XCTAssertEqual(restarted, .playing("A"))

        let moved = HistoryHostProbe(selected: "A")
        scheduler.enqueue { await moved.perform(.selection("B")) }
        scheduler.enqueue { await moved.perform(.playPause("B")) }
        await scheduler.runInReverseOrder()
        let dropped = await moved.audible
        XCTAssertNil(dropped)
    }

    func testStopAfterPlay_endsItWhetherPlayIsPendingOrAlreadyRunning() async {
        let scheduler = HeldHistoryTasks()
        let host = HistoryHostProbe(selected: "A")
        let lane = historyLane(scheduler, host)
        lane.submit(.playPause("A"))
        lane.submit(.stop)
        await scheduler.runInReverseOrder()
        let pending = await host.audible
        XCTAssertNil(pending, "audio started after the Stop that followed its Play")

        let running = await heldLane(selected: "A", holding: .playPause("A"))
        running.lane.submit(.stop)
        await running.finish()
        let applied = await running.host.applied
        XCTAssertEqual(applied, [.playPause("A"), .stop])
        let audible = await running.host.audible
        XCTAssertNil(audible)
    }

    func testPlayAfterStop_isNotEndedByIt() async {
        let scheduler = HeldHistoryTasks()
        let host = HistoryHostProbe(selected: "A")
        let lane = historyLane(scheduler, host)
        lane.submit(.stop)
        lane.submit(.playPause("A"))
        await scheduler.runInReverseOrder()
        let audible = await host.audible
        XCTAssertEqual(audible, .playing("A"))
        XCTAssertEqual(scheduler.launchCount, 1)
    }

    func testClicksOnANewlySelectedRow_reachItAfterItsSelection() async {
        let scheduler = HeldHistoryTasks()
        let host = HistoryHostProbe(selected: "A")
        let lane = historyLane(scheduler, host)
        lane.submit(.selection("B"))
        lane.submit(.playPause("B"))
        await scheduler.runInReverseOrder()
        let playing = await host.audible
        XCTAssertEqual(playing, .playing("B"))
        lane.submit(.selection("C"))
        lane.submit(.readAloud("C", text: "Displayed C"))
        await scheduler.runInReverseOrder()
        let reading = await host.audible
        XCTAssertEqual(reading, .reading("C", "Displayed C"), "Read aloud must speak the snapshot from its click")
    }

    func testNewRow_dropsClicksStillAimedAtThePreviousRow() async {
        let held = await heldLane()
        held.lane.submit(.playPause("A"))
        held.lane.submit(.readAloud("A", text: "Displayed A"))
        held.lane.submit(.version("A", .original))
        held.lane.submit(.selection("B"))
        await held.finish()
        let applied = await held.host.applied
        XCTAssertEqual(applied, [.selection("A"), .selection("B")])
        let audible = await held.host.audible
        XCTAssertNil(audible)
    }

    func testStop_dropsTheClicksBeforeItButKeepsTheirRow() async {
        let held = await heldLane()
        held.lane.submit(.selection("B"))
        held.lane.submit(.playPause("B"))
        held.lane.submit(.readAloud("B", text: "Displayed B"))
        held.lane.submit(.stop)
        held.lane.submit(.stop)
        await held.finish()
        let applied = await held.host.applied
        XCTAssertEqual(applied, [.selection("A"), .selection("B"), .stop])
        let selected = await held.host.selected
        XCTAssertEqual(selected, "B")
    }

    /// A row followed by its version keeps both; the latest version wins.
    func testVersion_keepsThePendingRowItBelongsTo() async {
        let held = await heldLane()
        held.lane.submit(.selection("B"))
        held.lane.submit(.version("B", .original))
        held.lane.submit(.playPause("B"))
        held.lane.submit(.version("B", .processed))
        await held.finish()
        let applied = await held.host.applied
        XCTAssertEqual(applied, [.selection("A"), .selection("B"), .playPause("B"), .version("B", .processed)])
    }

    func testClickBursts_stayBoundedWhileStopIsAlwaysKept() async {
        let held = await heldLane()
        for _ in 0..<1_000 { held.lane.submit(.playPause("A")) }
        held.lane.submit(.stop)
        for index in 0..<1_000 { held.lane.submit(.readAloud("A", text: "Displayed \(index)")) }
        XCTAssertEqual(held.scheduler.launchCount, 1, "a burst must keep one worker")
        await held.finish()
        let limit = DesktopHistoryEvent.maximumPendingActions
        let expected: [DesktopHistoryEvent] = [.selection("A"), .stop]
            + (0..<limit).map { .readAloud("A", text: "Displayed \($0)") }
        let applied = await held.host.applied
        XCTAssertEqual(applied, expected)
        XCTAssertEqual(held.scheduler.launchCount, 1)
    }

    private func historyLane(
        _ scheduler: HeldHistoryTasks, _ host: HistoryHostProbe
    ) -> DesktopEventDispatcher<DesktopHistoryEvent> {
        DesktopEventDispatcher(launch: scheduler.launcher, coalescing: DesktopHistoryEvent.coalesce) { event in
            await host.perform(event)
        }
    }

    /// A lane whose first event is held inside the host, so every later
    /// submission can only coalesce while it is in flight.
    private func heldLane(
        selected: String = "Z", holding first: DesktopHistoryEvent = .selection("A")
    ) async -> HeldLane {
        let scheduler = HeldHistoryTasks()
        let host = HistoryHostProbe(selected: selected)
        let gate = HistoryLaneGate()
        let entered = expectation(description: "The first event entered the host")
        let lane = DesktopEventDispatcher<DesktopHistoryEvent>(
            launch: scheduler.launcher, coalescing: DesktopHistoryEvent.coalesce
        ) { event in
            await gate.holdFirst { entered.fulfill() }
            await host.perform(event)
        }
        lane.submit(first)
        let drain = Task { await scheduler.runInReverseOrder() }
        await fulfillment(of: [entered], timeout: 2)
        return HeldLane(lane: lane, host: host, scheduler: scheduler, gate: gate, drain: drain)
    }
}

private struct HeldLane {
    let lane: DesktopEventDispatcher<DesktopHistoryEvent>
    let host: HistoryHostProbe
    let scheduler: HeldHistoryTasks
    let gate: HistoryLaneGate
    let drain: Task<Void, Never>

    func finish() async {
        await gate.resume()
        await drain.value
    }
}

/// The host rules these events rely on: Play/Pause toggles the audible run
/// of its record and otherwise starts only on the selected row, like Read
/// aloud; another row ends what is audible, and Stop ends everything.
private actor HistoryHostProbe {
    enum Audible: Equatable {
        case playing(String), paused(String), reading(String, String)
    }

    private(set) var selected: String
    private(set) var audible: Audible?
    private(set) var applied: [DesktopHistoryEvent] = []

    init(selected: String) { self.selected = selected }

    func perform(_ event: DesktopHistoryEvent) {
        applied.append(event)
        switch event {
        case .selection(let id):
            if id != selected { audible = nil }
            selected = id
        case .version: break
        case .playPause(let id):
            if audible == .playing(id) {
                audible = .paused(id)
            } else if audible == .paused(id) {
                audible = .playing(id)
            } else if id == selected {
                audible = .playing(id)
            }
        case .stop: audible = nil
        case .readAloud(let id, let text):
            if id == selected { audible = .reading(id, text) }
        }
    }
}

/// Holds only the first event that reaches it, until resumed.
private actor HistoryLaneGate {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdFirst(entered: () -> Void) async {
        guard !held else { return }
        held = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private final class HeldHistoryTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () async -> Void] = []
    private var launches = 0
    var launchCount: Int { lock.withLock { launches } }
    /// `enqueue` as the dispatcher's launcher.
    var launcher: @Sendable (@escaping @Sendable () async -> Void) -> Void {
        { [self] operation in self.enqueue(operation) }
    }
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock { launches += 1; operations.append(operation) }
    }
    func runInReverseOrder() async {
        let pending = lock.withLock { let pending = operations; operations.removeAll(); return pending }
        for operation in pending.reversed() { await operation() }
    }
}
