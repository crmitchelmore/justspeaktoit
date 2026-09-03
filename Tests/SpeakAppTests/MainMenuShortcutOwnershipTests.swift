import AppKit
import XCTest

@testable import SpeakApp

/// A configurable shortcut must be installed on exactly one main-menu item.
///
/// AppKit fires only the *first* main-menu item carrying a given key equivalent
/// but draws the shortcut on every item that has it, so Start/Stop Recording
/// rendered ⇧⌘S on both the App menu (SwiftUI `SpeakCommands`) and the Speak
/// menu (`MenuBarManager`) while only one of them ever ran. `MenuBarManager` is
/// the single owner; the App menu keeps the command without a shortcut.
@MainActor
final class MainMenuShortcutOwnershipTests: XCTestCase {
    func testAppMenuInstallsNoConfigurableShortcuts() {
        XCTAssertTrue(
            SpeakCommands.installedShortcutActions.isEmpty,
            "The App menu must not install configurable key equivalents; the Speak menu owns them"
        )
        XCTAssertFalse(SpeakCommands.installedShortcutActions.contains(.startStopRecording))
    }

    func testSpeakMenuCarriesTheStartStopRecordingBinding() throws {
        let shortcuts = makeShortcutManager()
        let binding = shortcuts.binding(for: .startStopRecording)
        try XCTSkipUnless(binding.isEnabled, "Start/Stop Recording is unbound in this environment")
        let mainMenu = makeMainMenu(with: shortcuts)

        guard let item = item(titled: "Start/Stop Recording", in: mainMenu) else {
            return XCTFail("The Speak menu should carry a Start/Stop Recording item")
        }

        XCTAssertFalse(item.keyEquivalent.isEmpty, "The Speak menu owns the shortcut")
        XCTAssertEqual(item.keyEquivalentModifierMask, binding.modifiers)
        XCTAssertEqual(item.action, #selector(AppDelegate.startStopRecording))
    }

    func testNoTwoMainMenuItemsShareAKeyEquivalent() {
        let mainMenu = makeMainMenu(with: makeShortcutManager())

        var seen: [String: String] = [:]
        for item in allItems(in: mainMenu) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)"
            if let existing = seen[key] {
                XCTFail("“\(existing)” and “\(item.title)” both install \(key)")
            }
            seen[key] = item.title
        }
        XCTAssertFalse(seen.isEmpty, "The built menu should install at least one shortcut")
    }

    // MARK: - Helpers

    private func makeShortcutManager() -> ShortcutManager {
        ShortcutManager(permissionsManager: PermissionsManager(statusProvider: { _ in .granted }))
    }

    /// The main menu as the app builds it: an App menu (SwiftUI's, which no
    /// longer installs configurable shortcuts) plus whatever `MenuBarManager`
    /// inserts. Built explicitly so no running `NSApplication` is needed.
    private func makeMainMenu(with shortcuts: ShortcutManager) -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")
        let appMenuItem = NSMenuItem(title: "Just Speak to It", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Just Speak to It")
        appMenu.addItem(NSMenuItem(title: "Start/Stop Recording", action: nil, keyEquivalent: ""))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let manager = MenuBarManager(shortcutManager: shortcuts, appSettings: AppSettings())
        manager.setupMainMenu(in: mainMenu)
        return mainMenu
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + allItems(in: submenu)
        }
    }

    private func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        allItems(in: menu).first { $0.title == title && !$0.keyEquivalent.isEmpty }
    }
}
