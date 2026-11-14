#if os(iOS)
import SpeakCore
import SwiftUI

/// A Settings sub-page, grouped the way iOS Settings groups its own (#1470).
///
/// Each page hosts one or more `SearchableSettingsSection`s. `sectionTitles`
/// is how search finds the page that owns a catalogue entry, so a section
/// moved between pages only needs its title moved here.
enum IOSSettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case transcription
    case postProcessing
    case apiKeys
    case recording
    case results
    case sync
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .transcription: return "Transcription"
        case .postProcessing: return "Polish"
        case .apiKeys: return "Providers & API Keys"
        case .recording: return "Recording & Shortcuts"
        case .results: return "Results & Recordings"
        case .sync: return "Sync & Transfer"
        case .privacy: return "Privacy & Diagnostics"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .transcription: return "waveform"
        case .postProcessing: return "wand.and.stars"
        case .apiKeys: return "key.fill"
        case .recording: return "mic.fill"
        case .results: return "tray.full.fill"
        case .sync: return "icloud.fill"
        case .privacy: return "hand.raised.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: return .gray
        case .transcription: return .blue
        case .postProcessing: return .purple
        case .apiKeys: return .orange
        case .recording: return .red
        case .results: return .green
        case .sync: return .cyan
        case .privacy: return .indigo
        }
    }

    /// The `SearchableSettingsSection` titles this page renders.
    var sectionTitles: [String] {
        switch self {
        case .general: return ["Appearance", "Language", "Edit raw configuration"]
        case .transcription: return ["Transcription"]
        case .postProcessing: return ["Post-Processing"]
        case .apiKeys: return ["Subscription", "API Keys"]
        case .recording: return ["Hardware Trigger", "Behavior", "Just Speak Keyboard", "Focus Capture Overrides"]
        case .results: return ["Saved Results", "Recordings"]
        case .sync: return ["Sync"]
        case .privacy: return ["Troubleshooting", "Capture Health", "Privacy & Debugging"]
        case .about: return ["About"]
        }
    }

    /// Sections shown on the Settings root itself, above the pages. The held
    /// microphone status (#1471) stays visible without opening a page.
    static let rootSectionTitles = ["System resources in use"]

    /// Root list groups, in order.
    static let groups: [[IOSSettingsPage]] = [
        [.general, .transcription, .postProcessing, .apiKeys],
        [.recording, .results],
        [.sync, .privacy],
        [.about]
    ]

    /// The page whose section matches a search entry's title.
    static func page(for entry: SettingsSearchEntry) -> IOSSettingsPage? {
        if entry.id.hasPrefix(IOSSettingsSearch.pageEntryPrefix) {
            return IOSSettingsPage(rawValue: String(entry.id.dropFirst(IOSSettingsSearch.pageEntryPrefix.count)))
        }
        return allCases.first { $0.sectionTitles.contains(entry.title) }
    }
}

/// A page opened from search, scrolled to and highlighting one entry.
struct IOSSettingsRevealTarget: Hashable, Identifiable {
    let page: IOSSettingsPage
    let entryID: String

    var id: String { entryID }
}

/// Renders a page's sections in a Form with the shared density styling, and
/// scrolls to and briefly highlights `revealEntryID` the first time it appears.
struct IOSSettingsPageView: View {
    let page: IOSSettingsPage
    var revealEntryID: String?

    @ObservedObject private var settings = AppSettings.shared
    @State private var highlightID: String?
    @State private var didReveal = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                content
            }
            .environment(\.settingsSearchHighlightID, highlightID)
            .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
            .listSectionSpacing(settings.visualDensity.listSectionSpacing)
            .controlSize(settings.visualDensity.isCompact ? .small : .regular)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard let revealEntryID, !didReveal else { return }
                didReveal = true
                // Let the push settle before scrolling the list it reveals.
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation { proxy.scrollTo(revealEntryID, anchor: .top) }
                highlightID = revealEntryID
                try? await Task.sleep(for: .seconds(2.5))
                highlightID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .transcription: TranscriptionSettingsPage()
        case .postProcessing: PostProcessingSettingsPage()
        case .apiKeys: ProvidersSettingsPage()
        case .recording: RecordingSettingsPage()
        case .results: ResultsSettingsPage()
        case .sync: SyncSettingsPage()
        case .privacy: PrivacyDiagnosticsSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}

/// A root-list row: tinted icon tile, page title and an optional status value.
struct IOSSettingsPageRow: View {
    let page: IOSSettingsPage
    var value: String?
    @ScaledMetric(relativeTo: .body) private var tileSize = 29.0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.systemImage)
                .font(.system(size: tileSize * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tileSize, height: tileSize)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: tileSize * 0.24))
                .accessibilityHidden(true)
            Text(page.title)
                .layoutPriority(1)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A navigation row label whose value must stay readable in full, such as a
/// selected model. The value sits on its own line under the title and wraps,
/// rather than truncating beside it to "OpenRouter › GPT-…".
struct SettingsValueLabel: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// Secondary guidance under a setting. Markdown `**bold**` marks the action or
/// choice that matters. Hidden in the Compact layout unless `alwaysShown`.
struct SettingsFootnote: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let text: Text
    private let alwaysShown: Bool

    /// Takes a `String` so copy can be concatenated or chosen at runtime;
    /// `LocalizedStringKey` still renders its markdown.
    init(_ markdown: String, alwaysShown: Bool = false) {
        self.text = Text(LocalizedStringKey(markdown))
        self.alwaysShown = alwaysShown
    }

    var body: some View {
        if alwaysShown || !settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
            text
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
