import SpeakCore

/// Something the "Search for anything" palette can run, besides revealing a setting.
struct CommandPaletteCommand: Identifiable, Hashable {
    enum Run: Hashable {
        /// Runs the action's registered shortcut handler, so the palette and the
        /// keyboard shortcut share one code path.
        case shortcut(ShortcutAction)
        case copyLastTranscript
    }

    static let idPrefix = "command."

    let run: Run
    let title: String
    let summary: String
    let systemImage: String
    let keywords: [String]

    var id: String {
        switch run {
        case .shortcut(let action): return Self.idPrefix + action.rawValue
        case .copyLastTranscript: return Self.idPrefix + "copyLastTranscript"
        }
    }

    /// The shortcut shown beside the command, if it has one.
    var shortcutAction: ShortcutAction? {
        if case .shortcut(let action) = run { return action }
        return nil
    }

    /// Projects the command into the shared settings index so commands rank with
    /// the same matcher (synonyms, typos, prefixes) as settings.
    var searchEntry: SettingsSearchEntry {
        SettingsSearchEntry(
            id: id, title: title, section: .shortcuts, systemImage: systemImage, summary: summary,
            keywords: keywords, platforms: .macOS
        )
    }
}

extension CommandPaletteCommand {
    /// Commands in display order. Settings pages are already settings results, and
    /// actions that act on another app's selection make no sense from inside Speak.
    static func all(in channel: DistributionChannel = .current) -> [CommandPaletteCommand] {
        catalogue.filter { $0.shortcutAction?.isAvailable(in: channel) ?? true }
    }

    private static let catalogue: [CommandPaletteCommand] = [
        shortcut(
            .startStopRecording, "Start or Stop Transcribing", "mic",
            "Start a recording, or stop the current one and transcribe it.",
            ["record", "recording", "transcribe", "transcription", "dictate", "dictation", "microphone", "listen"]
        ),
        shortcut(
            .speakClipboard, "Say Clipboard Aloud", "speaker.wave.2",
            "Read the text on the clipboard aloud with your default voice.",
            ["say", "speak", "read aloud", "text to speech", "tts", "voice", "clipboard"]
        ),
        shortcut(
            .pauseResumeTTS, "Pause or Resume Speaking", "playpause",
            "Pause or resume the voice that is reading aloud.",
            ["say", "speech", "tts", "pause", "resume", "playback"]
        ),
        shortcut(
            .stopTTS, "Stop Speaking", "stop.circle",
            "Stop reading aloud.",
            ["say", "speech", "tts", "stop", "silence", "quiet"]
        ),
        CommandPaletteCommand(
            run: .copyLastTranscript, title: "Copy Last Transcript",
            summary: "Copy your most recent transcript to the clipboard.",
            systemImage: "doc.on.doc",
            keywords: ["copy", "clipboard", "last", "latest", "recent", "transcript", "history"]
        ),
        shortcut(
            .openVoiceOutput, "Say Text…", "text.bubble",
            "Open Voice Output to type or paste text and hear it read aloud.",
            ["say", "speak", "text to speech", "tts", "voice output", "read aloud", "type"]
        ),
        shortcut(
            .showHistory, "Show History", "clock",
            "Review past recordings and transcripts.",
            ["history", "past", "recordings", "transcripts", "previous"]
        ),
        shortcut(
            .openDashboard, "Open Dashboard", "waveform",
            "Live stats, quick actions and your most recent session.",
            ["home", "dashboard", "overview", "stats"]
        ),
        shortcut(
            .openCorrections, "Open Corrections", "character.book.closed",
            "Curate your custom name and phrase corrections.",
            ["corrections", "names", "phrases", "vocabulary", "lexicon", "dictionary"]
        ),
        shortcut(
            .openTroubleshooting, "Open Troubleshooting", "stethoscope",
            "Diagnose common issues and get help.",
            ["help", "troubleshoot", "diagnose", "problem", "not working", "fix"]
        )
    ]

    private static func shortcut(
        _ action: ShortcutAction, _ title: String, _ systemImage: String, _ summary: String, _ keywords: [String]
    ) -> CommandPaletteCommand {
        CommandPaletteCommand(
            run: .shortcut(action), title: title, summary: summary, systemImage: systemImage, keywords: keywords
        )
    }
}

/// Pure ranking for the palette: matching actions first, then settings, so the
/// view only renders rows.
struct CommandPaletteSearch {
    enum Item: Hashable {
        case command(CommandPaletteCommand)
        case setting(SettingsSearchEntry)
    }

    struct Row: Identifiable, Hashable {
        let item: Item
        let matchedKeyword: String?
        let group: String

        var id: String {
            switch item {
            case .command(let command): return command.id
            case .setting(let entry): return entry.id
            }
        }
    }

    static let commandLimit = 6
    static let settingLimit = 30
    static let commandsGroup = "Actions"

    private let commands: [CommandPaletteCommand]
    private let commandsByID: [String: CommandPaletteCommand]
    private let commandIndex: SettingsSearchIndex
    private let settingsIndex: SettingsSearchIndex

    init(commands: [CommandPaletteCommand], settings: [SettingsSearchEntry]) {
        self.commands = commands
        commandsByID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commandIndex = SettingsSearchIndex(entries: commands.map(\.searchEntry))
        settingsIndex = SettingsSearchIndex(entries: settings)
    }

    /// For an empty query: every action, then recent and suggested settings.
    func rows(for query: String, recentSettingIDs: [String] = []) -> [Row] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let commandRows = commandIndex.search(query, limit: Self.commandLimit).compactMap { result in
                commandsByID[result.entry.id].map {
                    Row(item: .command($0), matchedKeyword: result.matchedKeyword, group: Self.commandsGroup)
                }
            }
            let settingRows = settingsIndex.search(query, limit: Self.settingLimit).map {
                Row(item: .setting($0.entry), matchedKeyword: $0.matchedKeyword, group: "Settings")
            }
            return commandRows + settingRows
        }
        let recents = recentSettingIDs.compactMap { settingsIndex.entry(id: $0) }
        let suggested = SettingsSearchCatalog.suggestedEntryIDs
            .filter { !recentSettingIDs.contains($0) }
            .compactMap { settingsIndex.entry(id: $0) }
        return commands.map { Row(item: .command($0), matchedKeyword: nil, group: Self.commandsGroup) }
            + recents.map { Row(item: .setting($0), matchedKeyword: nil, group: "Recent Settings") }
            + suggested.map { Row(item: .setting($0), matchedKeyword: nil, group: "Suggested Settings") }
    }

    /// Typeahead phrases from actions and settings.
    func completions(for query: String, limit: Int = 5) -> [String] {
        var seen = Set<String>()
        let phrases = commandIndex.completions(for: query, limit: limit)
            + settingsIndex.completions(for: query, limit: limit)
        return Array(phrases.filter { seen.insert($0.lowercased()).inserted }.prefix(limit))
    }
}
