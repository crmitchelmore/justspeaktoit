#if os(iOS)
import SpeakCore
import SpeakSync
import SwiftUI

/// The Settings root: a short recommended setup, then one row per sub-page,
/// grouped the way iOS Settings is (#1470). Search spans every page.
public struct SettingsView: View {
    /// Names the provider whose key the selected batch model needs, read from
    /// the same canonical resolver `batchAPIKey(for:)` uses. Deriving it means
    /// a provider added to the batch catalogue cannot silently inherit the
    /// OpenRouter wording while its request goes somewhere else.
    static func batchAPIKeyPrompt(for modelIdentifier: String) -> String {
        switch ModelCredentialResolver.requirement(
            for: modelIdentifier,
            purpose: .batchTranscription
        ) {
        case .notRequired:
            return "This model runs on device and needs no API key."
        case .apiKey(_, let providerName):
            return "Add your \(providerName) API key in Providers & API Keys to use this model."
        }
    }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var historySync = HistorySyncEngine.shared
    @Environment(\.iOSKeyboardEnabled) private var iOSKeyboardEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingAPIKeys = false
    @State private var revealTarget: IOSSettingsRevealTarget?
    @State private var rootHighlightID: String?
    @State private var searchQuery = ""
    @State private var searchIndex = SettingsSearchIndex(
        entries: IOSSettingsSearch.catalogEntries(keyboardEnabled: false)
    )
    @AppStorage("settingsSearch.recentEntryIDs") private var storedSearchRecents = ""

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            settingsList
                .environment(\.settingsSearchHighlightID, rootHighlightID)
                .overlay {
                    if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        IOSSettingsSearchResults(query: searchQuery, index: searchIndex) { entry in
                            reveal(entry, using: proxy)
                        }
                    }
                }
        }
            .searchable(text: $searchQuery, prompt: "Search settings")
            .searchSuggestions { searchSuggestions }
            .task(id: rootHighlightID) {
                guard rootHighlightID != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                rootHighlightID = nil
            }
            .onAppear {
                searchIndex = SettingsSearchIndex(
                    entries: IOSSettingsSearch.catalogEntries(keyboardEnabled: iOSKeyboardEnabled)
                        + IOSSettingsSearch.pageEntries()
                        + IOSSettingsSearch.apiKeyEntries(APIKeysView.entries(for: settings))
                )
            }
    }

    private var settingsList: some View {
        List {
            ForEach(IOSSettingsPage.rootSectionTitles, id: \.self) { title in
                SearchableSettingsSection(title) {
                    SystemResourcesStatusRows(monitor: IOSSystemResourceMonitor.shared)
                }
            }

            if !settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                Section {
                    RecommendedSetupCard()
                }
            }

            ForEach(Array(IOSSettingsPage.groups.enumerated()), id: \.offset) { _, pages in
                Section {
                    ForEach(pages) { page in
                        NavigationLink {
                            IOSSettingsPageView(page: page)
                        } label: {
                            IOSSettingsPageRow(page: page, value: status(for: page))
                        }
                        .accessibilityIdentifier("settingsPage.\(page.rawValue)")
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(settings.visualDensity.listSectionSpacing)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(
            settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) ? .inline : .automatic
        )
        .navigationDestination(item: $revealTarget) { target in
            IOSSettingsPageView(page: target.page, revealEntryID: target.entryID)
        }
        .navigationDestination(isPresented: $showingAPIKeys) {
            APIKeysView(settings: settings)
        }
    }

    /// The current choice a page holds, shown on its row like iOS Settings does.
    private func status(for page: IOSSettingsPage) -> String? {
        switch page {
        case .transcription:
            let location = settings.transcriptionLocation
            return location == .remote
                ? "\(location.displayName) · \(settings.remoteTranscriptionMode.displayName)"
                : location.displayName
        case .postProcessing:
            return settings.autoPostProcess ? "Auto" : nil
        case .apiKeys:
            let entries = APIKeysView.entries(for: settings)
            return "\(entries.filter(\.isStored).count) of \(entries.count)"
        case .recording:
            return settings.hardwareTriggerDestination.displayName
        case .sync:
            guard historySync.isSyncEnabled else { return "Off" }
            return historySync.state.isCloudAvailable ? "iCloud" : "Unavailable"
        case .about:
            return AboutSettingsPage.appVersion
        case .general, .results, .privacy:
            return nil
        }
    }

    /// Typeahead completions while typing; recent and suggested destinations
    /// before anything is typed.
    @ViewBuilder
    private var searchSuggestions: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            let recentIDs = SettingsSearchRecents.decode(storedSearchRecents)
            let ids = recentIDs + SettingsSearchCatalog.suggestedEntryIDs.filter { !recentIDs.contains($0) }
            ForEach(ids.compactMap { searchIndex.entry(id: $0) }) { entry in
                Label(entry.title, systemImage: recentIDs.contains(entry.id) ? "clock" : entry.systemImage)
                    .searchCompletion(entry.title)
                    .accessibilityIdentifier("settingsSearchSuggestion.\(entry.id)")
            }
        } else {
            ForEach(searchIndex.completions(for: query, limit: 5), id: \.self) { completion in
                Label(completion, systemImage: "magnifyingglass")
                    .searchCompletion(completion)
            }
        }
    }

    private func reveal(_ entry: SettingsSearchEntry, using proxy: ScrollViewProxy) {
        storedSearchRecents = SettingsSearchRecents.encode(
            SettingsSearchRecents.recording(entry.id, in: SettingsSearchRecents.decode(storedSearchRecents))
        )
        searchQuery = ""
        if IOSSettingsSearch.opensAPIKeys(entry) {
            showingAPIKeys = true
            return
        }
        if IOSSettingsPage.rootSectionTitles.contains(entry.title) {
            withAnimation { proxy.scrollTo(entry.id, anchor: .top) }
            rootHighlightID = entry.id
            return
        }
        guard let page = IOSSettingsPage.page(for: entry) else { return }
        Task { @MainActor in
            // Let the search overlay dismiss before pushing the page beneath it.
            try? await Task.sleep(for: .milliseconds(250))
            revealTarget = IOSSettingsRevealTarget(page: page, entryID: entry.id)
        }
    }
}

/// The three steps most people need, with the recommended choice in bold.
private struct RecommendedSetupCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recommended setup", systemImage: "star.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            step(1, "In **Transcription**, choose **Remote → Streaming** for live text, "
                + "or **Local** to keep audio on \(DeviceCopy.thisDevice).")
            step(2, "For Remote, **add the provider's key** in **Providers & API Keys**.")
            step(3, triggerStep)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settingsRecommendedSetup")
    }

    /// iPads and older iPhones have no Action Button, so they get the Control Center route.
    private var triggerStep: String {
        CaptureHardwareProfile.current().hasActionButton
            ? "In **Recording & Shortcuts**, set the **Action Button** to **Transcribe Voice**."
            : "In **Recording & Shortcuts**, add **Transcribe Voice** to **Control Center**."
    }

    private func step(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(markdown))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
#endif
