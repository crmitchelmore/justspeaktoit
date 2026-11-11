import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop

/// The sidebar's settings search, on the UI thread: each query is answered
/// synchronously from the shared index, and a chosen row opens its page and,
/// for a preference, reveals that field in Dictation preferences. Nothing here
/// touches the controller, so it never delays shutdown.
final class WindowsSettingsSearch {
    private let session = DesktopSettingsSearchSession(platform: .windows)

    /// Called from the native window event callback; returns false for other events.
    func handle(_ event: Int32, query: String, row: Int) -> Bool {
        switch event {
        case Int32(JSTI_EVENT_SETTINGS_SEARCH.rawValue):
            publish(session.results(for: query))
        case Int32(JSTI_EVENT_SETTINGS_SEARCH_OPEN.rawValue):
            guard let target = session.choose(row) else { return true }
            _ = jsti_window_show_page(Self.page(for: target.destination))
            if let field = target.fieldIndex { _ = jsti_window_reveal_configuration_field(field) }
        default:
            return false
        }
        return true
    }

    private func publish(_ rows: [DesktopSettingsSearchSession.Row]) {
        let strings = DesktopNativeStrings()
        let results = rows.prefix(50).map {
            JSTISettingsSearchResult(
                title: strings.add($0.title), detail: strings.add($0.detail), identifier: strings.add($0.identifier)
            )
        }
        let status = withExtendedLifetime(strings) {
            results.withUnsafeBufferPointer { jsti_window_set_settings_search_results($0.baseAddress, $0.count) }
        }
        if status != 0 { WindowsNative.update("Settings search results could not be shown.") }
    }

    /// Windows shows Corrections and Pronunciation as sidebar pages of their own.
    static func page(for destination: DesktopSettingsDestination) -> Int32 {
        switch destination {
        case .general: return Int32(JSTI_PAGE_GENERAL)
        case .transcription: return Int32(JSTI_PAGE_TRANSCRIPTION)
        case .postProcessing: return Int32(JSTI_PAGE_POST_PROCESSING)
        case .voiceOutput: return Int32(JSTI_PAGE_VOICE_OUTPUT)
        case .corrections: return Int32(JSTI_PAGE_CORRECTIONS)
        case .pronunciation: return Int32(JSTI_PAGE_PRONUNCIATION)
        case .profiles: return Int32(JSTI_PAGE_PROFILES)
        case .keyboard: return Int32(JSTI_PAGE_KEYBOARD)
        case .cloudSync: return Int32(JSTI_PAGE_CLOUD_SYNC)
        case .about: return Int32(JSTI_PAGE_ABOUT)
        }
    }
}
