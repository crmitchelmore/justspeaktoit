#if os(iOS)
import SpeakCore
import SwiftUI

/// iOS projection of the shared settings search catalogue.
enum IOSSettingsSearch {
    static let apiKeyEntryPrefix = "apiKey."

    /// Catalogue entries this build renders; sections behind an off feature flag
    /// are left out so search never offers a destination that isn't there.
    static func catalogEntries(keyboardEnabled: Bool) -> [SettingsSearchEntry] {
        SettingsSearchCatalog.entries(for: .iOS).filter { entry in
            switch entry.id {
            case "apiKeys.subscription": return PaidAccessFeature.isAvailableOnIOS
            case "ios.keyboard": return keyboardEnabled
            default: return true
            }
        }
    }

    /// One entry per provider key, generated from the API Keys page's own list.
    static func apiKeyEntries(_ keys: [APIKeyListEntry]) -> [SettingsSearchEntry] {
        keys.map { key in
            SettingsSearchEntry(
                id: apiKeyEntryPrefix + key.id,
                title: "\(key.title) API key",
                section: .apiKeys,
                systemImage: "key.fill",
                summary: "Add or remove the \(key.title) key (\(key.category)).",
                keywords: [key.title, "\(key.title) key", "api key", "token", key.category],
                platforms: .iOS
            )
        }
    }

    static let pageEntryPrefix = "ios.page."

    /// One entry per Settings sub-page, so a page's own name (for example
    /// "Results & Recordings") is searchable as well as the sections on it.
    static func pageEntries() -> [SettingsSearchEntry] {
        IOSSettingsPage.allCases.compactMap { page in
            guard SettingsSearchCatalog.entry(title: page.title, platform: .iOS) == nil else { return nil }
            return SettingsSearchEntry(
                id: pageEntryPrefix + page.rawValue,
                title: page.title,
                section: .general,
                systemImage: page.systemImage,
                summary: page.sectionTitles.joined(separator: ", "),
                keywords: page.sectionTitles,
                platforms: .iOS
            )
        }
    }

    /// Entries whose settings live on the API Keys page rather than the main list.
    static func opensAPIKeys(_ entry: SettingsSearchEntry) -> Bool {
        entry.id.hasPrefix(apiKeyEntryPrefix) || entry.id == "apiKeys.alibaba" || entry.id == "apiKeys.azure"
    }
}

private struct IOSSettingsSearchHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsSearchHighlightID: String? {
        get { self[IOSSettingsSearchHighlightKey.self] }
        set { self[IOSSettingsSearchHighlightKey.self] = newValue }
    }
}

/// A Settings section registered with settings search. Its title must match an
/// iOS entry in `SettingsSearchCatalog` (enforced by `SettingsSearchCoverageTests`);
/// search scrolls to it and tints its rows briefly.
struct SearchableSettingsSection<Content: View>: View {
    @Environment(\.settingsSearchHighlightID) private var highlightID
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let entryID = SettingsSearchCatalog.entry(title: title, platform: .iOS)?.id
        Section(title) {
            content
        }
        .listRowBackground(entryID != nil && highlightID == entryID ? Color.accentColor.opacity(0.18) : nil)
        .id(entryID ?? title)
    }
}

/// Results shown over Settings while a search is active.
struct IOSSettingsSearchResults: View {
    let query: String
    let index: SettingsSearchIndex
    let onSelect: (SettingsSearchEntry) -> Void
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        let results = index.search(query, limit: 30)
        List {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results, id: \.entry.id) { result in
                    row(result)
                }
            }
        }
        .accessibilityLabel(results.isEmpty ? "No settings found" : "\(results.count) settings found")
    }

    private func row(_ result: SettingsSearchResult) -> some View {
        let entry = result.entry
        let detail = result.matchedKeyword.map { "Matches “\($0)” · \(entry.summary)" } ?? entry.summary
        return Button {
            dismissSearch()
            onSelect(entry)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: entry.systemImage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(entry.resultAccessibilityIdentifier)
    }
}
#endif
