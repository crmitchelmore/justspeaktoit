import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// The fake system's login item. `system` is nil for a system that cannot be
/// read back, which then takes any request.
final class FakeLoginItem: @unchecked Sendable {
    static let shared = FakeLoginItem()
    private let lock = NSLock()
    private var system: DesktopLoginItemState? = .disabled
    private var failure: String?
    private var shown: [DesktopLoginItemState] = []
    private var details: [String] = []

    func reset(system: DesktopLoginItemState? = .disabled, failure: String? = nil) {
        lock.withLock { self.system = system; self.failure = failure; shown = []; details = [] }
    }
    func state(recorded: Bool?) -> DesktopLoginItemState {
        lock.withLock { system ?? (recorded == true ? .enabled : .disabled) }
    }
    func set(_ enabled: Bool) throws -> DesktopLoginItemState {
        try lock.withLock {
            if let failure { throw DesktopHostError(message: failure) }
            let requested: DesktopLoginItemState = enabled ? .enabled : .disabled
            guard let current = system else { return requested }
            guard current.isChangeable else { return current }
            system = requested
            return requested
        }
    }
    func show(_ state: DesktopLoginItemState, detail: String) {
        lock.withLock { shown.append(state); details.append(detail) }
    }
    var shownStates: [DesktopLoginItemState] { lock.withLock { shown } }
    var shownDetails: [String] { lock.withLock { details } }
}

extension FakePlatform {
    static var loginItemSettingsName: String { "Test Settings › Startup" }
    static func loginItemState(recorded: Bool?) async -> DesktopLoginItemState {
        FakeLoginItem.shared.state(recorded: recorded)
    }
    static func setLoginItem(_ enabled: Bool) async throws -> DesktopLoginItemState {
        try FakeLoginItem.shared.set(enabled)
    }
    static func showLoginItem(_ state: DesktopLoginItemState, detail: String) {
        FakeLoginItem.shared.show(state, detail: detail)
    }
}

/// General › Launch at login through the shared controller: the system's
/// registration is shown, and the switch reports the state the system reached.
final class DesktopHostLoginItemTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeLoginItem.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("login-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
    }

    override func tearDown() async throws {
        await controller?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private var systemSettings: String { FakePlatform.loginItemSettingsName }

    func testTheSwitchRegistersTheLoginItemAndShowsIt() async throws {
        let refreshed = await controller.refreshLoginItem()
        XCTAssertEqual(refreshed, .disabled)
        let turnedOn = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(turnedOn, .enabled)
        let stillOn = await controller.refreshLoginItem()
        XCTAssertEqual(stillOn, .enabled)
        let turnedOff = await controller.setLaunchAtLogin(false)
        XCTAssertEqual(turnedOff, .disabled)
        XCTAssertEqual(FakeLoginItem.shared.shownStates, [.disabled, .enabled, .enabled, .disabled])
        XCTAssertEqual(FakeLog.shared.allStatuses, [
            "Just Speak to It will start, minimised, when you sign in.",
            "Just Speak to It will no longer start when you sign in."
        ])
        XCTAssertEqual(
            FakeLoginItem.shared.shownDetails.last,
            "Start Just Speak to It minimised when you sign in, so dictation is always one shortcut away."
        )
        let recorded = await controller.settings.runAtLogin
        XCTAssertEqual(recorded, false)
    }

    func testTheSystemsSettingsCanKeepItOff() async throws {
        FakeLoginItem.shared.reset(system: .disabledBySystem)
        let reached = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(reached, .disabledBySystem)
        XCTAssertEqual(FakeLoginItem.shared.shownStates, [.disabledBySystem])
        XCTAssertEqual(FakeLog.shared.allStatuses, ["Launch at login is turned off in \(systemSettings)."])
        XCTAssertEqual(
            FakeLoginItem.shared.shownDetails,
            ["Turned off in \(systemSettings). Turn it on there to launch at login."]
        )
        let recorded = await controller.settings.runAtLogin
        XCTAssertEqual(recorded, false)
    }

    func testAPolicyCanKeepItOn() async throws {
        FakeLoginItem.shared.reset(system: .enabledBySystem)
        let reached = await controller.setLaunchAtLogin(false)
        XCTAssertEqual(reached, .enabledBySystem)
        XCTAssertEqual(FakeLog.shared.allStatuses, ["Your organisation's policy keeps Launch at login on."])
    }

    func testAFailedChangeIsReportedWithTheUnchangedState() async throws {
        FakeLoginItem.shared.reset(system: .disabled, failure: "Access is denied.")
        let reached = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(reached, .disabled)
        XCTAssertEqual(FakeLog.shared.allStatuses, ["Could not change Launch at login: Access is denied."])
        XCTAssertEqual(FakeLoginItem.shared.shownStates, [.disabled])
        let recorded = await controller.settings.runAtLogin
        XCTAssertNil(recorded)
    }

    func testAnUnreadableSystemShowsTheStateLastReached() async throws {
        FakeLoginItem.shared.reset(system: nil)
        let reached = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(reached, .enabled)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.refreshLoginItem()
        XCTAssertEqual(restored, .enabled)
    }

    func testAnUnavailableHostRecordsNothing() async throws {
        FakeLoginItem.shared.reset(system: .unavailable)
        let reached = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(reached, .unavailable)
        XCTAssertEqual(FakeLog.shared.allStatuses, ["This installation of Just Speak to It cannot start at login."])
        let recorded = await controller.settings.runAtLogin
        XCTAssertNil(recorded)
    }

    func testAClosedControllerChangesNothing() async throws {
        await controller.close()
        let reached = await controller.setLaunchAtLogin(true)
        XCTAssertEqual(reached, .unavailable)
        let system = FakeLoginItem.shared.state(recorded: nil)
        XCTAssertEqual(system, .disabled)
    }
}
