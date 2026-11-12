import AppKit
import SpeakCore
import SwiftUI

/// Custom menu commands for Speak.
struct SpeakCommands: Commands {
    let environment: AppEnvironment
    @ObservedObject private var updaterManager = UpdaterManager.shared
    /// Observed so that if the App menu ever reclaims a binding (see
    /// `installedShortcutActions`), rebinding it in Settings re-renders the menu
    /// item, the same way `MenuBarManager` rebuilds its menu.
    @ObservedObject private var shortcuts: ShortcutManager

    init(environment: AppEnvironment) {
        self.environment = environment
        _shortcuts = ObservedObject(wrappedValue: environment.shortcuts)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
#if !APP_STORE
            CheckForUpdatesView(updater: updaterManager.updater)
#else
            CheckForUpdatesView()
#endif
            Divider()
            startStopRecordingButton
        }

        CommandGroup(replacing: .help) {
            Button("\(ReleaseTrain.current.displayName) Help") {
                if let url = URL(string: "https://github.com/speak-app/speak") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Configurable shortcuts this command set installs on the App menu.
    ///
    /// Empty by design. `MenuBarManager` installs every configurable binding on
    /// the Speak menu, and AppKit fires only the *first* main-menu item carrying
    /// a given key equivalent while every such item still draws it — so
    /// Start/Stop Recording used to render its shortcut on two menus and fire
    /// from one of them. The App menu keeps the command for discoverability,
    /// without a shortcut; the Speak menu owns the binding.
    static let installedShortcutActions: Set<ShortcutAction> = []

    /// The App menu's Start/Stop Recording item. It carries a shortcut only when
    /// `installedShortcutActions` claims `.startStopRecording`, which it does
    /// not; a disabled or unmappable binding would leave it bare as well.
    @ViewBuilder
    private var startStopRecordingButton: some View {
        let binding = Self.installedShortcutActions.contains(.startStopRecording)
            ? shortcuts.binding(for: .startStopRecording)
            : nil
        let button = Button("Start/Stop Recording") {
            environment.main.toggleRecordingFromUI()
        }
        if let binding, let key = binding.keyEquivalent {
            button.keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            button
        }
    }
}
