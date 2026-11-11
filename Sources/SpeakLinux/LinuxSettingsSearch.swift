import Foundation
import SpeakCore
import CLinuxSupport
import SpeakDesktop

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
    /// The native list's limit.
    static let maximumResults = 50

    static func show(_ rows: [DesktopSettingsSearchSession.Row]) {
        let strings = DesktopNativeStrings()
        let results = rows.prefix(maximumResults).map { row in
            JSTISettingsSearchResult(
                title: strings.add(row.title), detail: strings.add(row.detail), identifier: strings.add(row.identifier)
            )
        }
        let status = withExtendedLifetime(strings) {
            results.withUnsafeBufferPointer { jsti_window_set_settings_search_results($0.baseAddress, $0.count) }
        }
        if status != 0 { LinuxHostPlatform.update("Settings search results could not be shown.") }
    }

    /// Opens the result's page, then reveals its preference field, if it has one.
    static func open(_ target: DesktopSettingsSearchTarget) {
        guard jsti_window_show_page(page(for: target.destination)) == 0 else { return }
        if let index = target.fieldIndex, index >= 0 {
            _ = jsti_window_reveal_configuration_field(index)
        }
    }

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
