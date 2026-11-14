import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings

/// The sidebar's "Search for anything" palette (Ctrl+K or Ctrl+F), on the UI
/// thread: each query is answered synchronously by the shared
/// `DesktopCommandPaletteSession` from the actions Windows can run, its
/// settings and the controller's History snapshot. A chosen setting opens its
/// page and, for a preference, reveals that field; an action runs as its
/// shortcut does; a History record is selected on the History page.
final class WindowsCommandPalette {
    private let session: DesktopCommandPaletteSession

    init(history: CommandPaletteHistorySnapshot) {
        session = DesktopCommandPaletteSession(
            platform: .windows, runnable: WindowsActionShortcutRun.runnable, history: history
        )
    }

    /// Called from the native window event callback; returns false for other events.
    func handle(_ event: DesktopNativeWindowEvent, query: String, row: Int, holder: WindowsEventContext) -> Bool {
        switch event {
        case .settingsSearch:
            if !DesktopNativeBindings.settingsSearchResults(session.results(for: query)) {
                WindowsNative.update("Search results could not be shown.")
            }
        case .settingsSearchOpen:
            guard let target = session.choose(row) else { return true }
            open(target, holder: holder)
        default:
            return false
        }
        return true
    }

    private func open(_ target: DesktopCommandPaletteTarget, holder: WindowsEventContext) {
        switch target {
        case .setting(let setting):
            // Windows shows Corrections and Pronunciation as sidebar pages of their own.
            _ = jsti_window_show_page(DesktopNativePage(setting.destination).rawValue)
            if let field = setting.fieldIndex { _ = jsti_window_reveal_configuration_field(field) }
        case .action(let action):
            let run = WindowsActionShortcutRun(action)
            if jsti_window_run_action(run.code, run.page) != 0 {
                WindowsNative.update("\(action.displayName) is not available right now.")
            }
        case .history(let identifier):
            _ = jsti_window_show_page(DesktopNativePage.history.rawValue)
            holder.submitHistoryPlayback(.reveal(identifier))
        }
    }
}
