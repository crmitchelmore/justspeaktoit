import Foundation
import SpeakCore
import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings

/// The sidebar's "Search for anything" palette (Ctrl+K or Ctrl+F), on the GTK
/// main thread. Ranking is in memory and synchronous, so it never joins the
/// settings queue that shutdown drains. Returns false for other events.
func linuxSettingsSearchEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    switch event {
    case .settingsSearch:
        LinuxSettingsSearch.show(holder.commandPalette.results(for: value))
    case .settingsSearchOpen:
        if let target = holder.commandPalette.choose(slot) { LinuxSettingsSearch.open(target, holder: holder) }
    default: return false
    }
    return true
}

enum LinuxSettingsSearch {
    /// The shortcut actions Linux can run; the shared catalogue picks the palette's actions from them.
    static let runnable = Set(DesktopShortcutAction.allCases.filter { LinuxActionShortcutRun($0) != .unavailable })

    static func show(_ rows: [DesktopSettingsSearchSession.Row]) {
        if !DesktopNativeBindings.settingsSearchResults(rows) {
            LinuxHostPlatform.update("Search results could not be shown.")
        }
    }

    /// Opens a setting's page and reveals its preference field, if it has one;
    /// runs an action as its shortcut does; selects a History record.
    static func open(_ target: DesktopCommandPaletteTarget, holder: LinuxEventContext) {
        switch target {
        case .setting(let setting):
            guard jsti_window_show_page(DesktopNativePage(setting.destination).rawValue) == 0 else { return }
            if let index = setting.fieldIndex, index >= 0 {
                _ = jsti_window_reveal_configuration_field(index)
            }
        case .action(let action):
            let run = LinuxActionShortcutRun(action)
            if jsti_window_run_action(run.code, run.page, run.slot) != 0 {
                LinuxHostPlatform.update("\(action.displayName) is not available right now.")
            }
        case .history(let identifier):
            guard jsti_window_show_page(DesktopNativePage.history.rawValue) == 0 else { return }
            holder.submitHistoryPlayback(.reveal(identifier))
        }
    }
}
