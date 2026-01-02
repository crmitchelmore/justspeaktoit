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

    /// Sets up the main application menu with shortcuts displayed.
    func setupMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

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

        // Voice quick switch submenu
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

        speakMenu.addItem(voiceMenuItem)

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
            title: "Settings...",
            action: ShortcutAction.openSettings,
            selector: #selector(AppDelegate.openSettings)
        )
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
            keyEquivalent: keyEquivalent(for: binding)
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
            keyEquivalent: keyEquivalent(for: binding)
        )
        item.keyEquivalentModifierMask = binding.modifiers
        menu.addItem(item)
    }

    private func keyEquivalent(for binding: KeyBinding) -> String {
        switch binding.keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 25: return "9"
        case 26: return "7"
        case 28: return "8"
        case 29: return "0"
        case 31: return "o"
        case 32: return "u"
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 40: return "k"
        case 43: return ","
        case 45: return "n"
        case 46: return "m"
        case 49: return " "
        case 53: return "\u{1B}"  // Escape
        default: return ""
        }
    }
}

// MARK: - Dock Menu Support

/// Manages the dock menu with quick actions.
@MainActor
final class DockMenuManager {
    private weak var historyManager: HistoryManager?

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
    }

    /// Creates the dock menu.
    func createDockMenu() -> NSMenu {
        let menu = NSMenu()

        // Quick actions
        let recordItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(AppDelegate.startStopRecording),
            keyEquivalent: ""
        )
        menu.addItem(recordItem)

        let speakClipboardItem = NSMenuItem(
            title: "Speak Clipboard",
            action: #selector(AppDelegate.speakClipboard),
            keyEquivalent: ""
        )
        menu.addItem(speakClipboardItem)

        menu.addItem(NSMenuItem.separator())

        // Recent items submenu
        let recentMenu = NSMenu(title: "Recent")
        let recentMenuItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentMenuItem.submenu = recentMenu

        if let historyManager {
            let recentItems = Array(historyManager.items.prefix(5))
            if recentItems.isEmpty {
                let emptyItem = NSMenuItem(title: "No recent items", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                recentMenu.addItem(emptyItem)
            } else {
                for item in recentItems {
                    let text = (item.postProcessedTranscription ?? item.rawTranscription ?? "Unknown")
                        .prefix(40)
                    let menuItem = NSMenuItem(
                        title: String(text) + (text.count >= 40 ? "..." : ""),
                        action: #selector(AppDelegate.openHistoryItem(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.representedObject = item.id
                    recentMenu.addItem(menuItem)
                }
            }
        }

        menu.addItem(recentMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(AppDelegate.openSettings),
            keyEquivalent: ""
        )
        menu.addItem(settingsItem)

        return menu
    }
}

// MARK: - Services Menu Integration

/// Registers Speak as a macOS Service for right-click menu integration.
@MainActor
final class ServicesProvider: NSObject {
    private weak var ttsManager: TextToSpeechManager?
    private weak var appSettings: AppSettings?

    init(ttsManager: TextToSpeechManager, appSettings: AppSettings) {
        self.ttsManager = ttsManager
        self.appSettings = appSettings
        super.init()
    }

    /// Registers the services with the system.
    func registerServices() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Service handler for "Speak with Speak".
    @objc func speakText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error?.pointee = "No text selected" as NSString
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let ttsManager else { return }
            do {
                _ = try await ttsManager.synthesize(text: text)
            } catch {
                // Error is handled by TTS manager
            }
        }
    }
}

// MARK: - Touch Bar Support

#if canImport(AppKit)
@available(macOS 10.12.2, *)
extension NSTouchBarItem.Identifier {
    static let speakRecord = NSTouchBarItem.Identifier("com.speak.touchbar.record")
    static let speakPlayPause = NSTouchBarItem.Identifier("com.speak.touchbar.playpause")
    static let speakVoiceSwitch = NSTouchBarItem.Identifier("com.speak.touchbar.voice")
}

/// Provides Touch Bar support for Speak.
@available(macOS 10.12.2, *)
@MainActor
final class TouchBarProvider: NSObject, NSTouchBarDelegate {
    private weak var mainManager: MainManager?
    private weak var ttsManager: TextToSpeechManager?
    private weak var appSettings: AppSettings?

    init(mainManager: MainManager, ttsManager: TextToSpeechManager, appSettings: AppSettings) {
        self.mainManager = mainManager
        self.ttsManager = ttsManager
        self.appSettings = appSettings
        super.init()
    }

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            .speakRecord,
            .speakPlayPause,
            .flexibleSpace,
            .speakVoiceSwitch,
        ]
        return touchBar
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .speakRecord:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record")!,
                target: self,
                action: #selector(recordTapped)
            )
            button.bezelColor = .systemRed
            item.view = button
            item.customizationLabel = "Record"
            return item

        case .speakPlayPause:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play/Pause")!,
                target: self,
                action: #selector(playPauseTapped)
            )
            item.view = button
            item.customizationLabel = "Play/Pause"
            return item

        case .speakVoiceSwitch:
            let item = NSPopoverTouchBarItem(identifier: identifier)
            item.collapsedRepresentationImage = NSImage(
                systemSymbolName: "person.wave.2",
                accessibilityDescription: "Voice"
            )
            item.customizationLabel = "Voice"

            let popoverBar = NSTouchBar()
            popoverBar.delegate = self
            popoverBar.defaultItemIdentifiers = [.init("voice1"), .init("voice2"), .init("voice3")]
            item.popoverTouchBar = popoverBar

            return item

        default:
            if identifier.rawValue.starts(with: "voice") {
                let item = NSCustomTouchBarItem(identifier: identifier)
                let voiceNumber = identifier.rawValue.replacingOccurrences(of: "voice", with: "")
                let button = NSButton(
                    title: "Voice \(voiceNumber)",
                    target: self,
                    action: #selector(voiceTapped(_:))
                )
                button.tag = Int(voiceNumber) ?? 1
                item.view = button
                return item
            }
            return nil
        }
    }

    @objc private func recordTapped() {
        mainManager?.toggleRecordingFromUI()
    }

    @objc private func playPauseTapped() {
        guard let ttsManager else { return }
        if ttsManager.isPlaying {
            ttsManager.pause()
        } else {
            ttsManager.resume()
        }
    }

    @objc private func voiceTapped(_ sender: NSButton) {
        guard let appSettings else { return }
        let favorites = appSettings.ttsFavoriteVoices
        let index = sender.tag - 1
        if index < favorites.count {
            appSettings.defaultTTSVoice = favorites[index]
        }
    }
}
#endif
