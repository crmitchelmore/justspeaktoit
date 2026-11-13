import Foundation

// Read aloud fields the Mac and iPhone share. Each is defined once here so both
// schemas validate the same key the same way (#1671).
extension SettingsSchema {
    /// The read aloud language: Automatic or a catalogue language.
    static let ttsLanguageIdentifierField = SettingsSchemaField(
        key: "ttsLanguageIdentifier", kind: .enumeration, summary: "Voice language, or automatic.",
        defaultValue: .string(VoiceOutputLanguageCatalog.normalizedIdentifier(nil)),
        allowedValues: voiceOutputLanguageIdentifiers)

    static let sonioxTTSRegionField = SettingsSchemaField(
        key: "sonioxTTSRegion", kind: .enumeration, summary: "Soniox speech region.",
        defaultValue: .string(SonioxTTSRegion.migrated(from: nil).rawValue),
        allowedValues: SonioxTTSRegion.allCases.map(\.rawValue))

    /// Each host narrows the range to its provider's (see `VoiceOutputProvider.speedRange`).
    static let ttsSpeedField = SettingsSchemaField(
        key: "ttsSpeed", kind: .number, summary: "Speaking rate; 1 is normal.", defaultValue: .double(1),
        range: 0.5...2)

    static var voiceOutputLanguageIdentifiers: [String] {
        let automatic = VoiceOutputLanguageCatalog.automaticIdentifier
        return [automatic] + VoiceOutputLanguageCatalog.options.map(\.id).filter { $0 != automatic }
    }
}
