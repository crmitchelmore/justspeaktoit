import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings

/// The sidebar's settings search, on the UI thread: each query is answered
/// synchronously from the shared index, and a chosen row opens its page and,
/// for a preference, reveals that field in Dictation preferences. Nothing here
/// touches the controller, so it never delays shutdown.
final class WindowsSettingsSearch {
    private let session = DesktopSettingsSearchSession(platform: .windows)

    /// Called from the native window event callback; returns false for other events.
    func handle(_ event: DesktopNativeWindowEvent, query: String, row: Int) -> Bool {
        switch event {
        case .settingsSearch:
            if !DesktopNativeBindings.settingsSearchResults(session.results(for: query)) {
                WindowsNative.update("Settings search results could not be shown.")
            }
        case .settingsSearchOpen:
            guard let target = session.choose(row) else { return true }
            // Windows shows Corrections and Pronunciation as sidebar pages of their own.
            _ = jsti_window_show_page(DesktopNativePage(target.destination).rawValue)
            if let field = target.fieldIndex { _ = jsti_window_reveal_configuration_field(field) }
        default:
            return false
        }
        return true
    }
}
