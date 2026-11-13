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
            id: "android.keepAudio", title: "Keep audio when a recording is cancelled", section: .general,
            systemImage: "xmark.bin",
            summary: "Keep cancelled cloud recordings in History so you can transcribe them later.",
            keywords: ["keep audio", "cancel", "discard", "delete recording", "cancelled recording"],
            settingKeys: ["keepAudioOnCancel"], platforms: .android
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
            id: "android.privacyPolicy", title: "Privacy policy", section: .about,
            systemImage: "hand.raised",
            summary: "Open the Just Speak to It privacy policy on the website.",
            keywords: ["privacy", "data", "policy", "data safety", "what is collected"],
            platforms: .android
        )
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
                    id: $0.id, title: $0.title, section: $0.section.rawValue, sectionTitle: $0.section.title,
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
