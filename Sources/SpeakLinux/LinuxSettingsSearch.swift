import Foundation
import SpeakCore
import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings

/// Sidebar settings search, on the GTK main thread. Ranking is in memory and
/// synchronous, so it never joins the settings queue that shutdown drains.
/// Returns false for other events.
func linuxSettingsSearchEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    switch event {
    case Int(JSTI_EVENT_SETTINGS_SEARCH):
        LinuxSettingsSearch.show(holder.settingsSearch.results(for: value))
    case Int(JSTI_EVENT_SETTINGS_SEARCH_OPEN):
        if let target = holder.settingsSearch.choose(slot) { LinuxSettingsSearch.open(target) }
    default: return false
    }
    return true
}

enum LinuxSettingsSearch {
    static func show(_ rows: [DesktopSettingsSearchSession.Row]) {
        if !DesktopNativeBindings.settingsSearchResults(rows) {
            LinuxHostPlatform.update("Settings search results could not be shown.")
        }
    }

    /// Opens the result's page, then reveals its preference field, if it has one.
    static func open(_ target: DesktopSettingsSearchTarget) {
        guard jsti_window_show_page(DesktopNativePage(target.destination).rawValue) == 0 else { return }
        if let index = target.fieldIndex, index >= 0 {
            _ = jsti_window_reveal_configuration_field(index)
        }
    }
}
