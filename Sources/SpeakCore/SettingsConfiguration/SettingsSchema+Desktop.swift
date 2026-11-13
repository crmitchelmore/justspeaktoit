import Foundation

// Windows and Linux settings, derived from `DesktopConfiguration.fields` so the
// portable preference catalogue stays the one definition. `DesktopConfiguration`
// remains the final validator: a host builds one from the merged values before
// it saves anything.
extension SettingsSchema {
    /// Keys a desktop host shows but never takes from the raw editor or
    /// automation: the automation write grant itself. Telemetry consent is an
    /// editor projection, so it is not in the schema at all.
    static let desktopReadOnlyKeys: Set<String> = [
        ApplicationPreferenceKey.allowAutomationConfigurationChanges.rawValue
    ]

    /// Choice fields whose stored value may be outside the listed choices (a
    /// voice provider's own quality, region or format name, or a speed mode a
    /// newer app added), so the schema checks only that they are strings.
    static let desktopOpenChoiceKeys: Set<String> = [
        SonioxVoicePreference.regionKey,
        VoiceSynthesisPreference.quality.key.rawValue,
        VoiceAudioFormat.preferenceKey,
        ApplicationPreferenceKey.speedMode.rawValue
    ]

    /// Whole-number settings the desktop stores as JSON numbers.
    static let desktopIntegerKeys: Set<String> = [
        ApplicationPreferenceKey.livePolishDebounceMs.rawValue,
        ApplicationPreferenceKey.livePolishMinDeltaChars.rawValue,
        ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue
    ]

    static let desktopFields: [SettingsSchemaField] = DesktopConfiguration.fields
        .filter { !DesktopConfiguration.editorProjectionKeys.contains($0.key) }
        .map(desktopField) + [
            SettingsSchemaField(
                key: ApplicationPreferenceKey.enableAutomationServer.rawValue, kind: .boolean,
                summary: "Local automation endpoint for the speak CLI and MCP. Change it in Settings.",
                defaultValue: .bool(false), isReadOnly: true)
        ]

    private static func desktopField(_ field: DesktopConfiguration.Field) -> SettingsSchemaField {
        let readOnly = desktopReadOnlyKeys.contains(field.key)
        switch field.kind {
        case .text:
            return SettingsSchemaField(
                key: field.key, kind: .string, summary: field.title, defaultValue: field.defaultValue.storage,
                isReadOnly: readOnly)
        case .boolean:
            return SettingsSchemaField(
                key: field.key, kind: .boolean, summary: field.title, defaultValue: field.defaultValue.storage,
                isReadOnly: readOnly)
        case .number(let range):
            let isInteger = desktopIntegerKeys.contains(field.key)
            var defaultValue = field.defaultValue.storage
            if isInteger, case .double(let number) = defaultValue { defaultValue = .int(Int(number)) }
            return SettingsSchemaField(
                key: field.key, kind: isInteger ? .integer : .number, summary: field.title,
                defaultValue: defaultValue, range: range, isReadOnly: readOnly)
        case .choice(let choices):
            // Modulate features are true, false, or absent for the provider default.
            if DesktopConfiguration.modulatePreferenceKeys.contains(field.key) {
                return SettingsSchemaField(
                    key: field.key, kind: .boolean,
                    summary: field.title + " Omit the key for the provider default.",
                    defaultValue: nil, isReadOnly: readOnly)
            }
            let open = desktopOpenChoiceKeys.contains(field.key)
            return SettingsSchemaField(
                key: field.key, kind: open ? .string : .enumeration, summary: field.title,
                defaultValue: field.defaultValue.storage,
                allowedValues: open ? nil : choices.map(\.value), isReadOnly: readOnly)
        }
    }
}
