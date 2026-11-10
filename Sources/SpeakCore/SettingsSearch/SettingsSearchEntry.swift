import Foundation

/// Hosts that render a settings search entry. An entry lists only the hosts whose
/// settings UI actually shows it; catalogue membership alone is not support.
public struct SettingsSearchPlatforms: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let macOS = SettingsSearchPlatforms(rawValue: 1 << 0)
    public static let iOS = SettingsSearchPlatforms(rawValue: 1 << 1)
    public static let windows = SettingsSearchPlatforms(rawValue: 1 << 2)
    public static let linux = SettingsSearchPlatforms(rawValue: 1 << 3)

    public static let apple: SettingsSearchPlatforms = [.macOS, .iOS]
}

/// Top-level destinations that host settings. Most are settings pages; the
/// corrections and troubleshooting pages also hold configuration. Raw values are
/// stable; each host maps a section onto its own navigation.
public enum SettingsSearchSection: String, CaseIterable, Hashable, Sendable {
    case general
    case transcription
    case postProcessing
    case profiles
    case voiceOutput
    case pronunciation
    case apiKeys
    case shortcuts
    case permissions
    case compareModels
    case dataMigration
    case about
    case corrections
    case troubleshooting

    public var title: String {
        switch self {
        case .general: return "General"
        case .transcription: return "Transcription"
        case .postProcessing: return "Post-processing"
        case .profiles: return "Profiles"
        case .voiceOutput: return "Voice Output"
        case .pronunciation: return "Pronunciation"
        case .apiKeys: return "API Keys"
        case .shortcuts: return "Keyboard"
        case .permissions: return "Permissions"
        case .compareModels: return "Compare Models"
        case .dataMigration: return "Data & Migration"
        case .about: return "About"
        case .corrections: return "Corrections"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .postProcessing: return "wand.and.stars"
        case .profiles: return "person.crop.rectangle.stack"
        case .voiceOutput: return "speaker.wave.3"
        case .pronunciation: return "character.book.closed"
        case .apiKeys: return "key.fill"
        case .shortcuts: return "keyboard"
        case .permissions: return "hand.raised.fill"
        case .compareModels: return "rectangle.split.3x1"
        case .dataMigration: return "arrow.up.arrow.down.square"
        case .about: return "info.circle"
        case .corrections: return "character.book.closed"
        case .troubleshooting: return "stethoscope"
        }
    }
}

/// One searchable settings destination: a settings page, card, section or row.
///
/// `id` is stable: hosts use it as the navigation anchor, the recents key and in
/// accessibility identifiers, so never rename one casually. `title` must equal the
/// heading the host renders; coverage tests use it to tie every settings card or
/// section back to the catalogue.
public struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let section: SettingsSearchSection
    public let systemImage: String
    public let summary: String
    /// Synonyms, control labels and phrases people search for.
    public let keywords: [String]
    /// Persisted setting names (settings-model property names) this entry hosts.
    public let settingKeys: [String]
    public let platforms: SettingsSearchPlatforms
    /// Whether the entry is a whole settings page rather than a card within it.
    public let isSectionRoot: Bool

    public init(
        id: String,
        title: String,
        section: SettingsSearchSection,
        systemImage: String,
        summary: String,
        keywords: [String] = [],
        settingKeys: [String] = [],
        platforms: SettingsSearchPlatforms,
        isSectionRoot: Bool = false
    ) {
        self.id = id
        self.title = title
        self.section = section
        self.systemImage = systemImage
        self.summary = summary
        self.keywords = keywords
        self.settingKeys = settingKeys
        self.platforms = platforms
        self.isSectionRoot = isSectionRoot
    }

    /// Accessibility identifier for a search result row showing this entry.
    public var resultAccessibilityIdentifier: String { "settingsSearchResult.\(id)" }
}
