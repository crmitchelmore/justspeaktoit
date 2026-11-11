import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class DesktopSystemResourcesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testPresentation_ListsHoldsAndOffersReleaseOnlyForReleasableCaptures() {
        let registry = SystemResourceRegistry(now: { Date(timeIntervalSince1970: 1_000) })
        let hotKey = registry.acquire(
            kind: .hotKey, title: "Dictation hotkey", reason: "Listens.", owner: "test", detail: "Ctrl+Alt+Space"
        )
        var view = DesktopSystemResources.presentation(
            holds: registry.holds, microphone: .idle, osName: "The sound server", now: start.addingTimeInterval(12)
        )
        XCTAssertNil(view.warning)
        XCTAssertFalse(view.canReleaseEverything, "The hotkey is not stopped by Release everything")
        XCTAssertEqual(view.rows.map(\.caption), ["Hotkey listener · for 12 s · Ctrl+Alt+Space"])
        XCTAssertNil(view.rows.first?.releaseTitle)
        XCTAssertEqual(view.microphone, "The sound server reports the microphone closed.")

        let mic = registry.acquire(
            kind: .microphone, title: "Dictation", reason: "Recording.", owner: "test",
            releaseTitle: "Cancel recording", release: {}
        )
        view = DesktopSystemResources.presentation(holds: registry.holds, microphone: .idle, osName: "OS")
        XCTAssertTrue(view.canReleaseEverything)
        XCTAssertEqual(view.rows.first { $0.kind == .microphone }?.releaseTitle, "Cancel recording")
        withExtendedLifetime((hotKey, mic)) {}
    }

    func testReleaseEverything_KeepsTheHotkey() async {
        let registry = SystemResourceRegistry()
        let released = Box(false)
        let hotKey = registry.acquire(kind: .hotKey, title: "Hotkey", reason: "", owner: "test", release: {
            XCTFail("Release everything must not stop the hotkey")
        })
        let mic = Box<SystemResourceToken?>(nil)
        mic.value = registry.acquire(kind: .microphone, title: "Mic", reason: "", owner: "test", release: {
            released.value = true
            mic.value?.end()
        })
        let count = await DesktopSystemResources.releaseEverything(registry: registry)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(released.value)
        XCTAssertEqual(registry.holds.map(\.kind), [.hotKey])
        let unknown = await DesktopSystemResources.release("not-a-uuid", registry: registry)
        XCTAssertFalse(unknown)
        withExtendedLifetime(hotKey) {}
    }

    func testMonitor_WarnsAndReportsOnceForAnUnclaimedMicrophone() {
        let registry = SystemResourceRegistry()
        let published = Box<[DesktopSystemResources.Presentation]>([])
        let reports = Box<[String]>([])
        let monitor = DesktopSystemResourcesMonitor(
            registry: registry, osName: "The sound server", probe: { true },
            publish: { published.value.append($0) }, report: { reports.value.append($0) }
        )
        monitor.sample(now: start)
        XCTAssertNil(published.value.last?.warning, "A mismatch shorter than the grace is not shown")
        monitor.sample(now: start.addingTimeInterval(5))
        monitor.sample(now: start.addingTimeInterval(7))
        XCTAssertNotNil(published.value.last?.warning)
        XCTAssertEqual(published.value.last?.headline, "Microphone open, not claimed by any feature")
        XCTAssertEqual(
            published.value.last?.canReleaseEverything, false,
            "Release everything reaches only registered holds, so it cannot stop an unclaimed capture"
        )
        XCTAssertEqual(reports.value.count, 1, "One report per episode")

        let mic = registry.acquire(kind: .microphone, title: "Dictation", reason: "", owner: "test")
        monitor.sample(now: start.addingTimeInterval(9))
        XCTAssertNil(published.value.last?.warning)
        XCTAssertEqual(published.value.last?.rows.map(\.title), ["Dictation"])
        let count = published.value.count
        monitor.sample(now: start.addingTimeInterval(9))
        XCTAssertEqual(published.value.count, count, "An unchanged view is not republished")
        withExtendedLifetime(mic) {}
    }
}
