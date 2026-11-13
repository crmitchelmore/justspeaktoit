import AppKit
import Foundation

/// Manages the application menu bar with keyboard shortcut hints.
@MainActor
final class MenuBarManager {
    private weak var shortcutManager: ShortcutManager?
    private weak var appSettings: AppSettings?

    private var speakMenu: NSMenu?

    init(shortcutManager: ShortcutManager, appSettings: AppSettings) {
        self.shortcutManager = shortcutManager
        self.appSettings = appSettings
    }

    /// Sets up the main menu. `mainMenu` is injectable so tests can assert its shortcuts.
    func setupMainMenu(in mainMenu: NSMenu? = NSApp.mainMenu) {
        guard let mainMenu else { return }

        // Find or create the "Speak" menu
        if let existingSpeakMenu = mainMenu.item(withTitle: "Speak") {
            speakMenu = existingSpeakMenu.submenu
        } else {
            let speakMenuItem = NSMenuItem(title: "Speak", action: nil, keyEquivalent: "")
            speakMenu = NSMenu(title: "Speak")
            speakMenuItem.submenu = speakMenu
            mainMenu.insertItem(speakMenuItem, at: 1)
        }

        rebuildSpeakMenu()
    }

    /// Rebuilds the Speak menu with current shortcuts.
    func rebuildSpeakMenu() {
        guard let speakMenu, shortcutManager != nil else { return }

        speakMenu.removeAllItems()

        // Recording section
        addMenuItem(
            to: speakMenu,
            title: "Start/Stop Recording",
            action: ShortcutAction.startStopRecording,
            selector: #selector(AppDelegate.startStopRecording)
        )

        speakMenu.addItem(NSMenuItem.separator())

        // TTS section
        addMenuItem(
            to: speakMenu,
            title: "Speak Selected Text",
            action: ShortcutAction.speakSelectedText,
            selector: #selector(AppDelegate.speakSelectedText)
        )

        addMenuItem(
            to: speakMenu,
            title: "Speak Clipboard",
            action: ShortcutAction.speakClipboard,
            selector: #selector(AppDelegate.speakClipboard)
        )

        addMenuItem(
            to: speakMenu,
            title: "Pause/Resume",
            action: ShortcutAction.pauseResumeTTS,
            selector: #selector(AppDelegate.pauseResumeTTS)
        )

        addMenuItem(
            to: speakMenu,
            title: "Stop Speaking",
            action: ShortcutAction.stopTTS,
            selector: #selector(AppDelegate.stopTTS)
        )

        speakMenu.addItem(NSMenuItem.separator())

        speakMenu.addItem(makeVoiceQuickSwitchItem())

        speakMenu.addItem(NSMenuItem.separator())

        // Navigation section
        addMenuItem(
            to: speakMenu,
            title: "Show History",
            action: ShortcutAction.showHistory,
            selector: #selector(AppDelegate.showHistory)
        )

        addMenuItem(
            to: speakMenu,
            title: "Settings…",
            action: ShortcutAction.openSettings,
            selector: #selector(AppDelegate.openSettings)
        )
    }

    private func makeVoiceQuickSwitchItem() -> NSMenuItem {
        let voiceSubmenu = NSMenu(title: "Quick Switch Voice")
        let voiceMenuItem = NSMenuItem(title: "Quick Switch Voice", action: nil, keyEquivalent: "")
        voiceMenuItem.submenu = voiceSubmenu

        addVoiceMenuItem(
            to: voiceSubmenu,
            title: "Voice 1",
            action: ShortcutAction.quickVoice1,
            selector: #selector(AppDelegate.quickVoice1)
        )
        addVoiceMenuItem(
            to: voiceSubmenu,
            title: "Voice 2",
            action: ShortcutAction.quickVoice2,
            selector: #selector(AppDelegate.quickVoice2)
        )
        addVoiceMenuItem(
            to: voiceSubmenu,
            title: "Voice 3",
            action: ShortcutAction.quickVoice3,
            selector: #selector(AppDelegate.quickVoice3)
        )

        return voiceMenuItem
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        action: ShortcutAction,
        selector: Selector
    ) {
        guard let shortcutManager else { return }

        let binding = shortcutManager.binding(for: action)
        let item = NSMenuItem(
            title: title,
            action: selector,
            keyEquivalent: binding.menuKeyEquivalent
        )
        item.keyEquivalentModifierMask = binding.modifiers
        item.isEnabled = binding.isEnabled
        menu.addItem(item)
    }

    private func addVoiceMenuItem(
        to menu: NSMenu,
        title: String,
        action: ShortcutAction,
        selector: Selector
    ) {
        guard let shortcutManager else { return }

        let binding = shortcutManager.binding(for: action)
        let item = NSMenuItem(
            title: title,
            action: selector,
            keyEquivalent: binding.menuKeyEquivalent
        )
        item.keyEquivalentModifierMask = binding.modifiers
        menu.addItem(item)
    }
}
