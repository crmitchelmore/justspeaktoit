import Foundation

/// Android Settings sections. Titles equal the English string resources the
/// Settings screen renders. One entry per cloud model and provider key is added
/// at runtime from the app's `CloudCatalog`.
extension SettingsSearchCatalog {
    static let androidEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "android.cloudModel", title: "Cloud transcription model", section: .transcription,
            systemImage: "waveform",
            summary: "The cloud model used when dictating in cloud mode.",
            keywords: ["transcription model", "model picker", "openai", "deepgram", "whisper", "provider"],
            settingKeys: ["cloud_model"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.language", title: "Dictation language", section: .transcription,
            systemImage: "globe",
            summary: "The language you speak. Automatic uses the phone's language.",
            keywords: ["language", "locale", "spoken language", "accent", "english", "spanish", "french", "german"],
            settingKeys: ["preferredLocale"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.personalCorrections", title: "Personal corrections", section: .corrections,
            systemImage: "character.book.closed",
            summary: "Words the recogniser gets wrong and how to write them; also sent to cloud models as vocabulary.",
            keywords: [
                "vocabulary", "dictionary", "custom words", "names", "spelling", "replace", "lexicon",
                "keyterms", "jargon"
            ],
            settingKeys: ["personal_corrections"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.cleanup", title: "Clean up transcripts", section: .postProcessing,
            systemImage: "wand.and.stars",
            summary: "Send the final transcript to the chosen cleanup model to fix punctuation and filler words.",
            keywords: [
                "post-processing", "polish", "cleanup", "llm", "openrouter", "grammar", "cleanup model",
                "anthropic", "claude", "openai", "gemini", "groq", "mistral"
            ],
            settingKeys: ["cleanup_enabled", "cleanup_model"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.cleanupPrompt", title: "Cleanup prompt", section: .postProcessing,
            systemImage: "text.quote",
            summary: "Replace the built-in cleanup instructions with your own system prompt.",
            keywords: [
                "custom prompt", "system prompt", "instructions", "post-processing prompt", "polish prompt",
                "tone", "style", "formatting"
            ],
            settingKeys: ["postProcessingSystemPrompt"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.profiles", title: "Dictation profiles", section: .profiles,
            systemImage: "person.crop.rectangle.stack",
            summary: "Named sets of cloud model, language and cleanup settings, chosen in the app or the keyboard.",
            keywords: [
                "profile", "profiles", "power mode", "preset", "mode", "work", "personal", "context",
                "per app", "custom prompt"
            ],
            settingKeys: ["dictationProfiles", "activeDictationProfileID"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.keepAudio", title: "Keep audio when a recording is cancelled", section: .general,
            systemImage: "xmark.bin",
            summary: "Keep cancelled cloud recordings in History so you can transcribe them later.",
            keywords: ["keep audio", "cancel", "discard", "delete recording", "cancelled recording"],
            settingKeys: ["keepAudioOnCancel"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.recordingSounds", title: "Recording sounds", section: .general,
            systemImage: "speaker.wave.2",
            summary: "Start and stop sounds, their profile and volume.",
            keywords: ["play start/stop sounds", "sound profile", "chime", "beep", "volume", "mute sounds"],
            settingKeys: ["recordingSoundsEnabled", "recordingSoundProfile", "recordingSoundVolume"],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.silenceDetection", title: "Stop recording after silence", section: .general,
            systemImage: "waveform.slash",
            summary: "Stop a Cloud recording and transcribe it once you have been quiet for a set time.",
            keywords: ["silence", "auto stop", "automatic stop", "pause", "quiet", "threshold", "hands-free"],
            settingKeys: ["silenceDetectionEnabled", "silenceThreshold", "silenceDuration"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.resourcesInUse", title: "System resources in use", section: .general,
            systemImage: "gauge.with.dots.needle.33percent",
            summary: "See what the app holds now, such as the microphone or a cloud request, and release it.",
            keywords: [
                "status", "resources", "microphone in use", "mic stuck", "release", "release everything",
                "stop recording", "orange dot", "privacy indicator"
            ],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.apiKeys", title: "API keys", section: .apiKeys, systemImage: "key.fill",
            summary: "Add or remove provider keys, encrypted with the Android Keystore.",
            keywords: ["credentials", "token", "keystore", "openrouter key", "openai key", "deepgram key"],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.privacy", title: "Privacy", section: .about, systemImage: "hand.raised",
            summary: "Choose whether to share anonymous analytics and crash reports. Both start off.",
            keywords: ["privacy", "telemetry", "analytics", "crash reports", "diagnostics", "consent", "opt out"],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.analytics", title: "Share anonymous analytics", section: .about,
            systemImage: "chart.bar",
            summary: "Off until you turn it on. Sends typed usage events to PostHog EU, never transcripts or audio.",
            keywords: ["analytics", "telemetry", "tracking", "usage data", "posthog", "opt out", "opt in"],
            settingKeys: ["analyticsConsent"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.diagnostics", title: "Send crash reports and diagnostics", section: .about,
            systemImage: "ladybug",
            summary: "Off until you turn it on. Sends crash reports to Sentry EU, never transcripts or audio.",
            keywords: ["crash reports", "diagnostics", "sentry", "errors", "bug reports", "opt out", "telemetry"],
            settingKeys: ["diagnosticsConsent"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.tipJar", title: "Support development", section: .about, systemImage: "heart.fill",
            summary: "Leave an optional tip through Google Play. Tips don't unlock features.",
            keywords: ["tip jar", "tip", "donate", "support", "buy me a coffee", "google play", "purchase"],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.setupGuide", title: "Setup guide", section: .general,
            systemImage: "sparkles",
            summary: "Run the first-run setup again: microphone, speech route, keyboard, tile and a test dictation.",
            keywords: [
                "onboarding", "setup", "first run", "welcome", "tutorial", "get started", "permissions",
                "keyboard", "quick settings tile", "test dictation"
            ],
            settingKeys: ["hasCompletedOnboarding"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.privacyPolicy", title: "Privacy policy", section: .about,
            systemImage: "hand.raised",
            summary: "Open the Just Speak to It privacy policy on the website.",
            keywords: ["privacy", "data", "policy", "data safety", "what is collected"],
            platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.reportIssue", title: "Report an issue", section: .about,
            systemImage: "ladybug",
            summary: "Preview a GitHub issue draft with privacy-safe diagnostics before you share it.",
            keywords: ["bug", "report", "feedback", "diagnostics", "github", "problem", "support"],
            platforms: .android
        )
    ]

    /// Android groups these entries under a heading other than their section's title, so search
    /// results name the heading people see on screen.
    static let androidSectionTitles: [String: String] = [
        "android.privacy": "Privacy",
        "android.analytics": "Privacy",
        "android.diagnostics": "Privacy"
    ]
}

/// The catalogue the Android app reads, as JSON. `SettingsSearchAndroidExportTests`
/// fails when the committed asset is stale; regenerate it with
/// `UPDATE_SETTINGS_SEARCH_ANDROID=1 swift test --filter SettingsSearchAndroidExportTests`.
public enum SettingsSearchAndroidExport {
    public static func json() throws -> Data {
        struct Entry: Encodable {
            let id, title, section, sectionTitle, summary: String
            let keywords, settingKeys: [String]
        }
        struct Document: Encodable {
            let version: Int
            let synonyms: [[String]]
            let entries: [Entry]
        }
        let document = Document(
            version: 1,
            synonyms: SettingsSearchSynonyms.groups,
            entries: SettingsSearchCatalog.entries(for: .android).map {
                Entry(
                    id: $0.id, title: $0.title, section: $0.section.rawValue,
                    sectionTitle: SettingsSearchCatalog.androidSectionTitles[$0.id] ?? $0.section.title,
                    summary: $0.summary, keywords: $0.keywords, settingKeys: $0.settingKeys
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }
}
