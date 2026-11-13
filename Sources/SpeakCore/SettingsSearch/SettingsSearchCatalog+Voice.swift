import Foundation

extension SettingsSearchCatalog {
    static let voiceEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "voiceOutput.defaultVoice", title: "Default Voice", section: .voiceOutput,
            systemImage: "speaker.wave.3",
            summary: "The text-to-speech voice, language and provider options.",
            keywords: ["voice", "tts voice", "speech language", "mistral model", "soniox region", "read aloud"],
            settingKeys: ["defaultTTSVoice", "ttsLanguageIdentifier", "mistralTTSModel", "sonioxTTSRegion"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "voiceOutput.quality", title: "Audio Quality & Performance", section: .voiceOutput,
            systemImage: "waveform.circle",
            summary: "Voice quality, speed and pitch.",
            keywords: ["quality", "speed", "rate", "pitch", "faster", "slower"],
            settingKeys: ["ttsQuality", "ttsSpeed", "ttsPitch"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "voiceOutput.export", title: "Output & Export", section: .voiceOutput,
            systemImage: "arrow.down.circle",
            summary: "File format, auto-play, saving and SSML.",
            keywords: [
                "file format", "mp3", "wav", "auto-play after synthesis", "save to recordings directory", "ssml"
            ],
            settingKeys: ["ttsOutputFormat", "ttsAutoPlay", "ttsSaveToDirectory", "ttsUseSSML"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "voiceOutput.favorites", title: "Favorite Voices", section: .voiceOutput, systemImage: "star.fill",
            summary: "Voices pinned for quick switching.",
            keywords: ["favourite voices", "quick switch voice", "pinned voices"],
            settingKeys: ["ttsFavoriteVoices"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "pronunciation.dictionary", title: "Pronunciation Dictionary", section: .pronunciation,
            systemImage: "text.book.closed",
            summary: "Teach voice output how to say words; entries also become keyterms.",
            keywords: ["pronounce", "replacement", "regex", "say words", "ignored keyterms"],
            settingKeys: ["ttsPronunciationDictionary", "assemblyAIIgnoredPronunciationTerms"],
            platforms: .macOS
        )
    ]

    static let keysAndShortcutEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "apiKeys.find", title: "Find API Keys", section: .apiKeys, systemImage: "magnifyingglass",
            summary: "Filter and sort provider keys by name, category or status.",
            keywords: ["search keys", "missing keys", "stored keys", "sort keys"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "apiKeys.subscription", title: "Subscription", section: .apiKeys, systemImage: "creditcard",
            summary: "Paid access that routes models for you without your own keys.",
            keywords: ["paid access", "billing", "restore purchases", "sign in with apple", "plan", "upgrade"],
            settingKeys: ["paidAccessRoutingEnabled"], platforms: .apple
        ),
        SettingsSearchEntry(
            id: "apiKeys.alibaba", title: "Alibaba workspace for new keys", section: .apiKeys, systemImage: "waveform",
            summary: "The Alibaba Model Studio workspace and region new keys belong to.",
            keywords: ["alibaba", "dashscope", "qwen", "region", "workspace"],
            platforms: .apple
        ),
        SettingsSearchEntry(
            id: "apiKeys.azure", title: "Azure Speech resource", section: .apiKeys, systemImage: "cloud",
            summary: "The Azure Speech endpoint or region your key belongs to.",
            keywords: ["azure", "endpoint", "region", "microsoft speech"],
            platforms: [.macOS, .iOS, .windows]
        ),
        SettingsSearchEntry(
            id: "apiKeys.encryptedSync", title: "Encrypted API-Key Sync", section: .apiKeys, systemImage: "lock.icloud",
            summary: "Sync API keys end-to-end encrypted between your devices.",
            keywords: ["sync keys", "icloud keychain", "enable api-key sync", "sync keys now", "cloudkit"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "apiKeys.localKeychain", title: "Local Keychain Storage", section: .apiKeys, systemImage: "key.fill",
            summary: "Keys are stored only in this Mac's Keychain.",
            keywords: ["keychain", "stored locally", "secure storage"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.triggerKey", title: "Trigger Key", section: .shortcuts, systemImage: "keyboard",
            summary: "The key you hold or tap to dictate.",
            keywords: ["hotkey", "fn key", "globe key", "dictation key", "right option", "record key"],
            settingKeys: ["selectedHotKey"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.activation", title: "Activation", section: .shortcuts, systemImage: "command.square",
            summary: "Hold, tap or double-tap to record, cancelling with Escape and keeping cancelled audio.",
            keywords: [
                "hold to talk", "push to talk", "toggle", "double tap", "cancel recording with escape",
                "discard recording", "activation style", "keep audio when a recording is cancelled", "keep audio",
                "cancel", "discard", "delete recording"
            ],
            settingKeys: ["hotKeyActivationStyle", "cancelRecordingOnEscape", "keepAudioOnCancel"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.timing", title: "Timing", section: .shortcuts, systemImage: "timer",
            summary: "Hold threshold, double-tap window and opening the microphone on key press.",
            keywords: ["hold threshold", "double tap window", "open the microphone on key press", "delay"],
            settingKeys: ["holdThreshold", "doubleTapWindow", "warmMicrophoneOnKeyPress"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.global", title: "Global Shortcuts", section: .shortcuts, systemImage: "globe",
            summary: "Shortcuts that work in any app: record, speak selection, paste last.",
            keywords: [
                "start/stop recording", "speak selected text", "speak clipboard", "paste last history item",
                "edit selection by voice", "system wide"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.app", title: "App Shortcuts", section: .shortcuts, systemImage: "app.badge",
            summary: "Shortcuts for navigating Speak's own windows and pages.",
            keywords: [
                "open settings", "show history", "quick switch voice", "navigation shortcuts", "rebind",
                "search for anything", "command palette"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.conflicts", title: "Conflicts", section: .shortcuts,
            systemImage: "exclamationmark.triangle",
            summary: "Shortcuts that clash with each other.",
            keywords: ["shortcut conflict", "duplicate shortcut", "clash"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "shortcuts.actions", title: "Actions", section: .shortcuts, systemImage: "arrow.counterclockwise",
            summary: "Reset shortcuts to their defaults.",
            keywords: ["reset shortcuts", "restore defaults"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "compareModels.input", title: "Input", section: .compareModels, systemImage: "waveform",
            summary: "Record or choose audio to compare models with.",
            keywords: ["compare input", "test audio"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "compareModels.models", title: "Models", section: .compareModels, systemImage: "rectangle.split.3x1",
            summary: "Pick which models to run side by side.",
            keywords: ["select models", "save results to history", "benchmark"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "compareModels.scoreboard", title: "Scoreboard", section: .compareModels, systemImage: "trophy",
            summary: "Accuracy and speed results from your comparisons.",
            keywords: ["results", "accuracy", "word error rate", "copy as markdown", "copy as json"],
            platforms: .macOS
        )
    ]

    static let aboutEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "about.version", title: "Version", section: .about, systemImage: "info.circle",
            summary: "Version, build, release notes and updates.",
            keywords: ["release notes", "check for updates", "build number", "what's new", "changelog"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.feedback", title: "Feedback & Support", section: .about,
            systemImage: "bubble.left.and.bubble.right",
            summary: "Report an issue or request a feature.",
            keywords: ["report issue", "bug", "request feature", "github", "contact", "help"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.privacy", title: "Privacy", section: .about, systemImage: "hand.raised",
            summary: "Crash reports and diagnostics, anonymous analytics and the privacy policy.",
            keywords: [
                "send crash reports and diagnostics", "crash reports", "diagnostics", "sentry",
                "share anonymous analytics", "telemetry", "tracking", "privacy policy", "opt out",
            ],
            settingKeys: ["diagnosticsConsent", "analyticsEnabled"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.transferToIOS", title: "Transfer to iOS", section: .about,
            systemImage: "iphone.and.arrow.forward",
            summary: "Move your settings and keys to the iPhone app with a QR code.",
            keywords: ["generate qr code", "iphone", "export settings", "copy settings"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.support", title: "Support Development", section: .about, systemImage: "heart.fill",
            summary: "Sponsor or tip the developer.",
            keywords: ["github sponsors", "ko-fi", "tip jar", "donate"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.dependencies", title: "Dependencies", section: .about, systemImage: "shippingbox",
            summary: "Open-source packages Speak uses.",
            keywords: ["open source", "acknowledgements", "credits"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "about.legal", title: "Legal", section: .about, systemImage: "doc.text",
            summary: "Licence and legal information.",
            keywords: ["view license (mit)", "licence", "terms"],
            platforms: .macOS
        )
    ]
}
