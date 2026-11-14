import Foundation

/// Something the "Search for anything" palette can run, besides revealing a
/// setting or a History item. One catalogue serves every desktop: the Mac
/// lists the actions its channel allows, Windows and Linux the ones their
/// action shortcuts can run.
public struct CommandPaletteAction: Identifiable, Hashable, Sendable {
    public enum Run: Hashable, Sendable {
        /// Runs the action's shortcut handler, so the palette and the keyboard
        /// shortcut share one code path.
        case shortcut(DesktopShortcutAction)
        case copyLastTranscript
    }

    public static let idPrefix = "command."

    public let run: Run
    public let title: String
    public let summary: String
    public let systemImage: String
    public let keywords: [String]

    public init(run: Run, title: String, summary: String, systemImage: String, keywords: [String]) {
        self.run = run
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.keywords = keywords
    }

    public var id: String {
        switch run {
        case .shortcut(let action): return Self.idPrefix + action.rawValue
        case .copyLastTranscript: return Self.idPrefix + "copyLastTranscript"
        }
    }

    /// The shortcut action the command runs, if it runs one.
    public var shortcut: DesktopShortcutAction? {
        if case .shortcut(let action) = run { return action }
        return nil
    }

    /// The automation identifier of the command's palette row.
    public var resultAccessibilityIdentifier: String { "commandPaletteResult.\(id)" }

    /// Projects the command into the shared settings index so commands rank with
    /// the same matcher (synonyms, typos, prefixes) as settings.
    public var searchEntry: SettingsSearchEntry {
        SettingsSearchEntry(
            id: id, title: title, section: .shortcuts, systemImage: systemImage, summary: summary,
            keywords: keywords, platforms: [.macOS, .windows, .linux]
        )
    }
}

extension CommandPaletteAction {
    /// Every command in display order. Settings pages are already settings
    /// results, and actions that act on another app's selection make no sense
    /// from inside the app. Hosts filter this to what they can run.
    public static let catalogue: [CommandPaletteAction] = [
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
        CommandPaletteAction(
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

    /// The catalogue's shortcut commands whose action is in `runnable`, in
    /// display order. Commands that run no shortcut are left to the host.
    public static func runnable(_ runnable: Set<DesktopShortcutAction>) -> [CommandPaletteAction] {
        catalogue.filter { $0.shortcut.map(runnable.contains) ?? false }
    }

    private static func shortcut(
        _ action: DesktopShortcutAction, _ title: String, _ systemImage: String, _ summary: String,
        _ keywords: [String]
    ) -> CommandPaletteAction {
        CommandPaletteAction(
            run: .shortcut(action), title: title, summary: summary, systemImage: systemImage, keywords: keywords
        )
    }
}
