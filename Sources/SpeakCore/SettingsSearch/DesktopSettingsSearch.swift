import Foundation

/// Desktop settings pages a search result can open. Each host maps these onto
/// its own page identifiers (`JSTI_PAGE_*`).
public enum DesktopSettingsDestination: String, CaseIterable, Sendable {
    case general
    case transcription
    case postProcessing
    case voiceOutput
    case corrections
    case pronunciation
    case profiles
    case keyboard
    case cloudSync
    case about
}

/// Where a chosen desktop result goes: a page, and for a preference field the
/// field to reveal (by `DesktopConfiguration.fields` index) and its group.
public struct DesktopSettingsSearchTarget: Equatable, Sendable {
    public let destination: DesktopSettingsDestination
    public let fieldIndex: Int?
    public let fieldGroup: String?
}

/// Windows and Linux settings search. Every `DesktopConfiguration` field is indexed
/// automatically; hand-built cards come from `SettingsSearchCatalog` entries
/// marked `.windows` / `.linux`.
public enum DesktopSettingsSearch {
    public static let fieldEntryPrefix = "desktop.field."

    public static func entries(for platform: SettingsSearchPlatforms) -> [SettingsSearchEntry] {
        SettingsSearchCatalog.entries(for: platform) + fieldEntries(platforms: [.windows, .linux])
    }

    static func fieldEntries(platforms: SettingsSearchPlatforms) -> [SettingsSearchEntry] {
        DesktopConfiguration.fields.map { field in
            var keywords = [field.group]
            if case .choice(let choices) = field.kind { keywords += choices.map(\.title) }
            return SettingsSearchEntry(
                id: fieldEntryPrefix + field.key,
                title: field.title,
                section: section(forFieldGroup: field.group),
                systemImage: "slider.horizontal.3",
                summary: "\(field.group) preference.",
                keywords: keywords,
                settingKeys: [field.key],
                platforms: platforms
            )
        }
    }

    /// The page that hosts a `DesktopConfiguration` field group.
    public static func destination(forFieldGroup group: String) -> DesktopSettingsDestination {
        switch group {
        case "Transcription": return .transcription
        case "Post-processing": return .postProcessing
        case "Keyboard": return .keyboard
        case "Corrections": return .corrections
        default: return .general
        }
    }

    public static func target(for entry: SettingsSearchEntry) -> DesktopSettingsSearchTarget {
        if entry.id.hasPrefix(fieldEntryPrefix) {
            let key = String(entry.id.dropFirst(fieldEntryPrefix.count))
            if let index = DesktopConfiguration.fields.firstIndex(where: { $0.key == key }) {
                let group = DesktopConfiguration.fields[index].group
                return DesktopSettingsSearchTarget(
                    destination: destination(forFieldGroup: group), fieldIndex: index, fieldGroup: group
                )
            }
        }
        let page = pageOverrides[entry.id] ?? destination(for: entry.section)
        return DesktopSettingsSearchTarget(destination: page, fieldIndex: nil, fieldGroup: nil)
    }

    /// Entries whose desktop page differs from their section's usual page.
    private static let pageOverrides: [String: DesktopSettingsDestination] = [
        "desktop.cloudSync": .cloudSync, "windows.apiKeys": .transcription, "apiKeys.azure": .transcription
    ]

    static func destination(for section: SettingsSearchSection) -> DesktopSettingsDestination {
        switch section {
        case .general, .apiKeys, .permissions, .dataMigration: return .general
        case .transcription, .compareModels: return .transcription
        case .postProcessing: return .postProcessing
        case .voiceOutput: return .voiceOutput
        case .corrections, .troubleshooting: return .corrections
        case .pronunciation: return .pronunciation
        case .profiles: return .profiles
        case .shortcuts: return .keyboard
        case .about: return .about
        }
    }

    private static func section(forFieldGroup group: String) -> SettingsSearchSection {
        switch group {
        case "Transcription": return .transcription
        case "Post-processing": return .postProcessing
        case "Keyboard": return .shortcuts
        case "Corrections": return .corrections
        case "Voice Output": return .voiceOutput
        default: return .general
        }
    }
}

/// One host's live search state: the index, the last results and session recents.
/// Hosts call `results(for:)` as the query changes and `choose(_:)` with a row.
public final class DesktopSettingsSearchSession {
    public struct Row: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let identifier: String
    }

    private let index: SettingsSearchIndex
    private var shown: [SettingsSearchEntry] = []
    private var recents: [String] = []

    public init(platform: SettingsSearchPlatforms) {
        index = SettingsSearchIndex(entries: DesktopSettingsSearch.entries(for: platform))
    }

    /// Ranked rows for `query`; recent destinations when the query is empty.
    public func results(for query: String, limit: Int = 12) -> [Row] {
        let results: [(SettingsSearchEntry, String?)]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = recents.compactMap { index.entry(id: $0) }.map { ($0, nil) }
        } else {
            results = index.search(query, limit: limit).map { ($0.entry, $0.matchedKeyword) }
        }
        shown = results.map(\.0)
        return results.map { entry, keyword in
            let page = entry.isSectionRoot ? "Settings page" : entry.section.title
            let detail = keyword.map { "\(page) · Matches “\($0)”" } ?? "\(page) · \(entry.summary)"
            return Row(title: entry.title, detail: detail, identifier: entry.resultAccessibilityIdentifier)
        }
    }

    /// Typeahead phrases that extend `query`.
    public func completions(for query: String) -> [String] {
        index.completions(for: query, limit: 5)
    }

    /// The target for a row from the last `results(for:)` call, recorded as recent.
    public func choose(_ row: Int) -> DesktopSettingsSearchTarget? {
        guard shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        recents = SettingsSearchRecents.recording(entry.id, in: recents)
        return DesktopSettingsSearch.target(for: entry)
    }
}
