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
            id: "android.cleanup", title: "Clean up transcripts", section: .postProcessing,
            systemImage: "wand.and.stars",
            summary: "Send the final transcript to OpenRouter to fix punctuation and filler words.",
            keywords: ["post-processing", "polish", "cleanup", "llm", "openrouter", "grammar"],
            settingKeys: ["cleanup_enabled"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.keepAudio", title: "Keep audio when a recording is cancelled", section: .general,
            systemImage: "xmark.bin",
            summary: "Keep cancelled cloud recordings in History so you can transcribe them later.",
            keywords: ["keep audio", "cancel", "discard", "delete recording", "cancelled recording"],
            settingKeys: ["keepAudioOnCancel"], platforms: .android
        ),
        SettingsSearchEntry(
            id: "android.apiKeys", title: "API keys", section: .apiKeys, systemImage: "key.fill",
            summary: "Add or remove provider keys, encrypted with the Android Keystore.",
            keywords: ["credentials", "token", "keystore", "openrouter key", "openai key", "deepgram key"],
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
