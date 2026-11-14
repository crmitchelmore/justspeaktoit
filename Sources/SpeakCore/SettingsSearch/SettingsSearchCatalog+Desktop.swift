import Foundation

/// Hand-built Windows and Linux settings groups. `DesktopConfiguration` fields are
/// indexed automatically by `DesktopSettingsSearch`; only list headings here.
extension SettingsSearchCatalog {
    static let desktopEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "desktop.startup", title: "Startup", section: .general, systemImage: "power",
            summary: "Start Just Speak to It when you sign in.",
            keywords: ["launch at login", "start at login", "autostart", "boot"],
            settingKeys: ["runAtLogin"], platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.resourcesInUse", title: "System resources in use", section: .general,
            systemImage: "gauge.with.dots.needle.33percent",
            summary: "See what Just Speak to It holds right now (microphone, audio, connections, hotkey) "
                + "and release it.",
            keywords: [
                "status", "microphone in use", "mic indicator", "release microphone", "release everything",
                "what is using the microphone", "network connections", "background", "pulseaudio", "pipewire",
                "wasapi"
            ],
            platforms: [.linux, .windows]
        ),
        SettingsSearchEntry(
            id: "desktop.dataBackup", title: "Data backup", section: .dataMigration, systemImage: "archivebox",
            summary: "Save History, optional audio and app profiles in a ZIP backup, or restore one.",
            keywords: ["backup", "export history", "zip", "restore", "include saved recording audio", "migrate"],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.portableConfiguration", title: "Portable configuration", section: .dataMigration,
            systemImage: "square.and.arrow.up",
            summary: "Import or export portable preferences as JSON.",
            keywords: ["import preferences", "export preferences", "json", "transfer settings"],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.apiKeys", title: "API Keys", section: .apiKeys, systemImage: "key.fill",
            summary: "Add, validate and remove provider API keys, and check account balances.",
            keywords: [
                "manage api keys", "credentials", "token", "openrouter key", "openai key", "deepgram key", "balance",
                "credit", "billing"
            ],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.providerCredentials", title: "Provider credentials", section: .apiKeys,
            systemImage: "key.horizontal",
            summary: "Enter a new key for one provider.",
            keywords: ["new api key", "provider", "saved key"],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.model", title: "Model", section: .transcription, systemImage: "waveform",
            summary: "The transcription model and its provider key.",
            keywords: ["transcription model", "model picker", "provider", "api key for the selected provider"],
            settingKeys: ["liveTranscriptionModel", "batchTranscriptionModel", "transcriptionMode"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.localModels", title: "Local models", section: .transcription, systemImage: "externaldrive",
            summary: "Download or import whisper.cpp models and use a GPU.",
            keywords: ["download model", "hugging face", "ggml", "whisper", "vulkan", "gpu", "offline"],
            settingKeys: ["localTranscriptionModel"], platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.compareModels", title: "Compare Models", section: .compareModels,
            systemImage: "rectangle.split.3x1",
            summary: "Record once and compare transcription models side by side.",
            keywords: ["benchmark", "accuracy", "test models"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.recoveredKeywords", title: "Recovered keyword edits", section: .transcription,
            systemImage: "arrow.uturn.backward",
            summary: "Restore or discard keyword edits saved from an earlier session.",
            keywords: ["restore keywords", "discard saved edit"],
            settingKeys: ["recoveredTranscriptionKeywords", "transcriptionKeywordsLastReconciled"],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.cleanup", title: "Clean-up", section: .postProcessing, systemImage: "wand.and.stars",
            summary: "Turn post-processing on and choose a local or remote model and prompt.",
            keywords: [
                "enable post-processing", "polish", "llm", "openrouter", "model source", "local", "remote",
                "instructions", "prompt", "lexicon directives"
            ],
            settingKeys: [
                "postProcessingEnabled", "postProcessingModel", "postProcessingIncludeLexiconDirectives",
                "postProcessingIncludeContextTags"
            ],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.localLLMs", title: "Downloaded local LLMs", section: .postProcessing,
            systemImage: "cpu",
            summary: "Download and manage GGUF models for local clean-up.",
            keywords: ["gguf", "llama", "local cleanup", "download llm"],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.shortcut", title: "Shortcut", section: .shortcuts, systemImage: "keyboard",
            summary: "The dictation shortcut and command-line toggles.",
            keywords: ["hotkey", "toggle", "global shortcut", "keyboard shortcut", "--toggle", "activation style"],
            settingKeys: ["selectedHotKey", "hotKeyActivationStyle", "hotKeyActivation", "cancelRecordingOnEscape"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.actionShortcuts", title: "Action shortcuts", section: .shortcuts, systemImage: "command",
            summary: "Shortcuts for read aloud, paste last and quick voices.",
            keywords: ["speak clipboard", "paste last history", "quick voice", "stop speech", "rebind"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.voice", title: "Voice", section: .voiceOutput, systemImage: "speaker.wave.3",
            summary: "The read-aloud voice and favourites.",
            keywords: ["read aloud", "tts", "text to speech", "favourite voice", "voice picker"],
            settingKeys: ["defaultTTSVoice", "ttsFavoriteVoices"], platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.voiceProviderKey", title: "Voice provider key", section: .voiceOutput,
            systemImage: "key.fill",
            summary: "The API key the selected voice provider uses.",
            keywords: ["voice api key", "elevenlabs key", "tts key"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.selectedTextSpeech", title: "Selected-text speech", section: .voiceOutput,
            systemImage: "text.bubble",
            summary: "Read selected text aloud from any app.",
            keywords: [
                "speak selection", "read selected text", "accessibility", "voice edit", "edit selection by voice"
            ],
            platforms: .linux
        ),
        SettingsSearchEntry(
            id: "desktop.cloudSync", title: "iCloud sync", section: .general, systemImage: "icloud",
            summary: "Sign in with your Apple ID to sync History and import keys from your Mac.",
            keywords: ["apple id", "sync history with my mac", "import api keys from my mac", "cloudkit"],
            platforms: [.windows, .linux]
        ),
        SettingsSearchEntry(
            id: "desktop.correctionLearning", title: "Correction learning", section: .corrections,
            systemImage: "character.book.closed",
            summary: "Learn corrections you make to inserted text.",
            keywords: ["auto corrections", "learn corrections", "promotion threshold"],
            platforms: .linux
        )
    ] + windowsEntries

    /// Windows cards and dialogs (`layoutSettingsCard`, group boxes and dialog captions
    /// in Sources/CWindowsSupport) whose titles no shared desktop entry already matches.
    static let windowsEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "windows.readAloud", title: "Read aloud", section: .voiceOutput, systemImage: "speaker.wave.2",
            summary: "Read the selected History transcript, typed text or a clipboard snapshot aloud.",
            keywords: [
                "speak transcript", "tts", "text to speech", "choose voice", "text and export", "export wav",
                "clipboard snapshot", "stop speech"
            ],
            platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.audioOutputBackup", title: "Audio, output and backup", section: .general,
            systemImage: "mic",
            summary: "The microphone, where finished text goes, and ZIP backups of History, audio and app profiles.",
            keywords: [
                "microphone", "input device", "text output", "backup", "zip", "restore backup", "saved audio",
                "export history", "migrate"
            ],
            settingKeys: ["preferredAudioInputUID"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.appBehaviour", title: "App behaviour", section: .general, systemImage: "gearshape.2",
            summary: "Theme, launch at login, automation and where recordings are stored.",
            keywords: [
                "theme", "dark mode", "light mode", "appearance", "launch at login", "start at login", "autostart",
                "allow automation", "recording storage", "open folder", "delete all audio", "inspect backup"
            ],
            settingKeys: ["appearance", "runAtLogin", "recordingsDirectory"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.apiKeys", title: "API keys", section: .apiKeys, systemImage: "key.fill",
            summary: "Add, validate and remove provider API keys in Windows Credential Manager, and check balances.",
            keywords: [
                "manage api keys", "credentials", "credential manager", "token", "openrouter key", "openai key",
                "deepgram key", "save key", "balance", "credit", "billing"
            ],
            platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.textOutput", title: "Text output", section: .general, systemImage: "text.cursor",
            summary: "How finished text reaches the app you started in, and what happens if you switch apps.",
            keywords: ["paste", "insert text", "destination policy", "app switch", "deliver to"],
            settingKeys: ["appSwitchDelivery"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.outputMethod", title: "Output method", section: .general, systemImage: "doc.on.clipboard",
            summary: "Insert then paste, type into the field only, or copy to the clipboard.",
            keywords: ["smart insert", "type into field", "clipboard only", "copy to clipboard", "paste"],
            settingKeys: ["textOutputMethod"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.insertion", title: "Insertion", section: .general, systemImage: "character.cursor.ibeam",
            summary: "Insert at the cursor or replace the field, and restore the clipboard after pasting.",
            keywords: ["insert at cursor", "replace all", "restore clipboard", "accessibility insertion"],
            settingKeys: ["accessibilityInsertionMode", "restoreClipboard"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.automationSetup", title: "CLI and MCP setup", section: .general, systemImage: "terminal",
            summary: "Install the speak command and connect MCP clients.",
            keywords: ["cli", "mcp", "speak command", "automation", "terminal", "claude", "agents"],
            settingKeys: ["enableAutomationServer"], platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.personalCorrections", title: "Personal corrections", section: .corrections,
            systemImage: "character.book.closed",
            summary: "Canonical spellings and spoken variants, applied before optional post-processing.",
            keywords: [
                "edit corrections", "spelling", "spoken variants", "custom words", "lexicon", "automatic rules",
                "context rules", "suggestions"
            ],
            platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.pronunciationDictionary", title: "Pronunciation dictionary", section: .pronunciation,
            systemImage: "textformat.abc",
            summary: "Words, phonetic pronunciations and text replacements for Read aloud.",
            keywords: ["phonetic", "ipa", "text replacement", "pronounce", "regular expression", "legacy dictionary"],
            platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.perAppProfiles", title: "Per-app profiles", section: .profiles,
            systemImage: "person.crop.rectangle.stack",
            summary: "Give specific apps their own model, language and clean-up prompt.",
            keywords: ["app profiles", "per app", "application", "model per app", "prompt per app"],
            platforms: .windows
        ),
        SettingsSearchEntry(
            id: "windows.localCleanupModels", title: "Downloaded local cleanup models", section: .postProcessing,
            systemImage: "cpu",
            summary: "Download and manage GGUF models for clean-up on this PC.",
            keywords: ["gguf", "llama", "local llm", "local cleanup", "download llm", "offline"],
            platforms: .windows
        )
    ]
}
