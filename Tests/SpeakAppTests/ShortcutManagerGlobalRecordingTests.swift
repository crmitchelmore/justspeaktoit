import XCTest

@testable import SpeakApp

/// Covers the removal of the shipped global ⇧⌘S recording shortcut.
///
/// Changing `defaultKeyBinding` alone reached only fresh installs: `loadBindings` rewrites a
/// stored binding only when it still matches a shipped default, so every user who had
/// already launched the app kept the system-wide hotkey they never chose.
@MainActor
final class ShortcutManagerGlobalRecordingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.justspeaktoit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadBindings_withTheShippedGlobalRecordingBinding_migratesItToAppLocal() throws {
        try store([.startStopRecording: KeyBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: true)])

        let manager = makeManager()

        let binding = manager.binding(for: .startStopRecording)
        XCTAssertFalse(binding.isGlobal, "the unchosen system-wide ⇧⌘S should not survive an upgrade")
        XCTAssertEqual(binding.keyCode, 1)
        XCTAssertEqual(binding.modifiers, [.command, .shift])
    }

    func testLoadBindings_withAReboundRecordingShortcut_leavesTheUserChoiceAlone() throws {
        let chosen = KeyBinding(keyCode: 35, modifiers: [.control, .option], isGlobal: true)  // ⌃⌥P
        try store([.startStopRecording: chosen])

        let manager = makeManager()

        XCTAssertEqual(manager.binding(for: .startStopRecording), chosen)
    }

    func testLoadBindings_withGlobalAlreadyTurnedOff_leavesTheUserChoiceAlone() throws {
        let chosen = KeyBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: false)
        try store([.startStopRecording: chosen])

        let manager = makeManager()

        XCTAssertEqual(manager.binding(for: .startStopRecording), chosen)
    }

    /// The settings view keys the Global toggle and the card an action lands in off
    /// `supportsGlobalShortcut`. Dropping the action from it would leave an existing user's
    /// still-global binding filed under "App Shortcuts" with no control to switch it off.
    func testStartStopRecording_stillSupportsGlobal_soTheToggleRemains() {
        XCTAssertTrue(ShortcutAction.startStopRecording.supportsGlobalShortcut)
        XCTAssertFalse(ShortcutAction.startStopRecording.isGlobalByDefault)
        XCTAssertFalse(ShortcutAction.startStopRecording.defaultKeyBinding.isGlobal)
    }

    func testFreshInstall_registersNoGlobalRecordingShortcut() {
        let manager = makeManager()

        XCTAssertFalse(manager.binding(for: .startStopRecording).isGlobal)
    }

    /// ⇧⌘S is Save As in many apps, which is the stated reason for dropping the default.
    func testShiftCommandSRecordingBinding_isReportedAsASystemConflict() throws {
        try store([.startStopRecording: KeyBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: false)])

        let manager = makeManager()

        XCTAssertTrue(
            manager.conflicts.contains { $0.action == .startStopRecording },
            "binding recording to ⇧⌘S should warn about Save As"
        )
    }

    // MARK: - Helpers

    private func makeManager() -> ShortcutManager {
        ShortcutManager(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            defaults: defaults
        )
    }

    private func store(_ bindings: [ShortcutAction: KeyBinding]) throws {
        let data = try JSONEncoder().encode(bindings)
        defaults.set(data, forKey: "customShortcutBindings")
    }
}

/// Escape must cancel a recording whatever else is held.
final class KeyboardShortcutModifierTests: XCTestCase {
    /// The recording hotkey can be a chord such as ⌥Space, and a hold keeps it physically
    /// down, so the cancelling Escape arrives carrying ⌥. Matching it against an empty
    /// required set would never fire.
    func testEscape_ignoresModifiers() {
        XCTAssertTrue(KeyboardShortcut.escape.ignoresModifiers)
    }

    /// ⌘R stays exact so it cannot be hijacked from ⌃⌘R or ⇧⌘R in another app.
    func testCommandR_doesNotIgnoreModifiers() {
        XCTAssertFalse(KeyboardShortcut.commandR.ignoresModifiers)
        XCTAssertEqual(KeyboardShortcut.commandR.requiredModifiers, .command)
    }

    /// Both sides of the match are clamped to this set, so a shortcut declaring a flag
    /// outside it could never fire.
    func testTrackedModifiers_coverEveryDeclaredRequirement() {
        for shortcut in [KeyboardShortcut.commandR, .escape] {
            XCTAssertEqual(
                shortcut.requiredModifiers.subtracting(KeyboardShortcut.trackedModifiers),
                [],
                "\(shortcut) requires a modifier the matcher does not track"
            )
        }
    }
}
