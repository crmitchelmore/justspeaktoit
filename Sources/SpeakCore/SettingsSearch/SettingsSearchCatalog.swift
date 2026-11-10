import Foundation

/// The canonical, declarative index of every settings destination on every host.
///
/// Add an entry whenever you add a settings card, section, page or persisted
/// setting. Hosts render search from this catalogue, and coverage tests fail when
/// a settings heading or persisted setting is missing from it. See
/// Docs/settings-search.md.
public enum SettingsSearchCatalog {
    public static let entries: [SettingsSearchEntry] =
        sectionRoots + generalEntries + transcriptionEntries + postProcessingEntries
            + voiceEntries + keysAndShortcutEntries + aboutEntries + iOSEntries + desktopEntries
            + androidEntries

    /// Entries a host shows. Hosts may append runtime entries (for example one per
    /// API-key provider) generated from the shared provider catalogue.
    public static func entries(for platform: SettingsSearchPlatforms) -> [SettingsSearchEntry] {
        entries.filter { $0.platforms.isSuperset(of: platform) }
    }

    /// Shown before anything is typed: the destinations people look for most.
    public static let suggestedEntryIDs: [String] = [
        "transcription.mode",
        "apiKeys",
        "shortcuts.triggerKey",
        "general.microphone",
        "general.output",
        "postProcessing.cleanup",
        "ios.transcription",
        "ios.apiKeys",
        "ios.behavior",
        "ios.postProcessing",
        "desktop.apiKeys",
        "desktop.model",
        "desktop.shortcut"
    ]

    /// Looks up the entry a host heading belongs to on one platform.
    public static func entry(title: String, platform: SettingsSearchPlatforms) -> SettingsSearchEntry? {
        titleLookup[platform.rawValue]?[title]
    }

    private static let titleLookup: [Int: [String: SettingsSearchEntry]] = {
        var lookup: [Int: [String: SettingsSearchEntry]] = [:]
        for platform in [SettingsSearchPlatforms.macOS, .iOS, .windows, .linux, .android] {
            var titles: [String: SettingsSearchEntry] = [:]
            for entry in entries where entry.platforms.contains(platform) && !entry.isSectionRoot {
                titles[entry.title] = titles[entry.title] ?? entry
            }
            lookup[platform.rawValue] = titles
        }
        return lookup
    }()

    static let sectionRoots: [SettingsSearchEntry] = SettingsSearchSection.allCases.map { section in
        SettingsSearchEntry(
            id: section.rawValue,
            title: section.title,
            section: section,
            systemImage: section.systemImage,
            summary: sectionSummaries[section] ?? "",
            keywords: sectionKeywords[section] ?? [],
            settingKeys: section == .corrections ? ["autoCorrectionsEnabled", "autoCorrectionsPromotionThreshold"] : [],
            platforms: desktopPages.contains(section) ? [.macOS, .windows, .linux] : .macOS,
            isSectionRoot: true
        )
    }

    /// Sections that are also pages in the Windows and Linux settings windows.
    private static let desktopPages: Set<SettingsSearchSection> = [
        .general, .transcription, .postProcessing, .voiceOutput, .corrections, .pronunciation, .profiles,
        .shortcuts, .about
    ]

    private static let sectionSummaries: [SettingsSearchSection: String] = [
        .general: "Microphone, language, text output, appearance, HUD, sounds and app behaviour.",
        .transcription: "Where transcription runs, models, hands-free dictation and silence detection.",
        .postProcessing: "Clean up transcripts with an LLM, keyterms and cleanup context.",
        .profiles: "Per-app profiles that change behaviour for specific apps.",
        .voiceOutput: "Text-to-speech voice, quality, format and favourites.",
        .pronunciation: "Pronunciation dictionary for voice output and keyterms.",
        .apiKeys: "Add, validate and sync API keys for every provider.",
        .shortcuts: "Trigger key, activation style, timing and app shortcuts.",
        .permissions: "Microphone, accessibility and other system permissions.",
        .compareModels: "Record once and compare transcription models side by side.",
        .dataMigration: "Export, import and migrate settings, history and keys between devices.",
        .about: "Version, release notes, feedback, privacy and licences.",
        .corrections: "Personal corrections, lexicon and automatic correction learning.",
        .troubleshooting: "Diagnose recording, permissions and delivery problems."
    ]

    private static let sectionKeywords: [SettingsSearchSection: [String]] = [
        .general: ["preferences", "options"],
        .postProcessing: ["polish", "cleanup", "llm", "pre-processing"],
        .profiles: ["per-app", "app specific"],
        .voiceOutput: ["tts", "text to speech", "read aloud"],
        .apiKeys: ["credentials", "tokens", "providers"],
        .shortcuts: ["hotkeys", "keyboard shortcuts", "key bindings"],
        .permissions: ["privacy", "accessibility", "microphone access"],
        .compareModels: ["benchmark", "accuracy", "test models"],
        .dataMigration: ["export", "import", "backup", "transfer", "move to new mac"],
        .about: ["version", "licence", "license", "credits"],
        .corrections: ["auto corrections", "lexicon", "learn corrections", "promotion threshold"],
        .troubleshooting: ["diagnostics", "help", "not working", "debug"]
    ]
}
