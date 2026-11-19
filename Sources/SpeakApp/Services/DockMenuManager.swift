import AppKit
import Foundation

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
                        title: String(text) + (text.count >= 40 ? "…" : ""),
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
            title: "Settings…",
            action: #selector(AppDelegate.openSettings),
            keyEquivalent: ""
        )
        menu.addItem(settingsItem)

        return menu
    }
}
