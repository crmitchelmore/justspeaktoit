import Foundation

// The Android app's persisted settings, keyed by their `AppPreferences` key.
// API keys are never part of a document. The app reads this list from a
// committed asset (`SettingsSchemaAndroidExport`), and its tests fail when a
// preference has no field here or an app enum drifts from `allowedValues`.
extension SettingsSchema {
    private typealias Field = SettingsSchemaField

    /// Names of the app's `RecognitionMode`; null means "not chosen yet".
    static let androidRecognitionModes = ["OnDevice", "SpeechService", "Cloud"]
    /// Names of the app's history `Retention`.
    static let androidHistoryRetentions = ["Off", "Week", "Month", "Forever"]

    static let androidFields: [SettingsSchemaField] = {
        let transcriptionModels = CloudCatalogAndroidExport.transcriptionModels.map(\.id)
        let cleanupModels = CloudCatalogAndroidExport.cleanupModels.map(\.id)
        return [
            Field(key: "chosen_mode", kind: .optionalString,
                  summary: "Recognition mode: OnDevice, SpeechService or Cloud; null picks the best available.",
                  defaultValue: .null, allowedValues: androidRecognitionModes),
            Field(key: "cloud_model", kind: .enumeration, summary: "Model used when dictating in cloud mode.",
                  defaultValue: transcriptionModels.first.map { .string($0) }, allowedValues: transcriptionModels),
            Field(key: "preferredLocale", kind: .enumeration,
                  summary: "Spoken language, or automatic for the phone's language.",
                  defaultValue: .string(TranscriptionLanguageCatalog.automaticIdentifier),
                  allowedValues: TranscriptionLanguageCatalog.options.map(\.id)),
            Field(key: "personal_corrections", kind: .stringMap,
                  summary: "Spelling to the comma-separated words the recogniser writes instead.",
                  defaultValue: .object([:])),
            Field(key: "cleanup_enabled", kind: .boolean, summary: "Clean up final transcripts with a model.",
                  defaultValue: .bool(false)),
            Field(key: "cleanup_model", kind: .enumeration, summary: "Model used to clean up transcripts.",
                  defaultValue: .string(ModelCatalog.defaultPostProcessingModel), allowedValues: cleanupModels),
            Field(key: "keepAudioOnCancel", kind: .boolean,
                  summary: "Keep a cancelled cloud recording's audio in History.",
                  defaultValue: .bool(SpeechDefaults.keepAudioOnCancel)),
            Field(key: "handsFreeDictationEnabled", kind: .boolean,
                  summary: "Speech starts and stops Cloud recordings.",
                  defaultValue: .bool(SharedApplicationPreferences.handsFreeDictationEnabled.iOS.defaultValue)),
            Field(key: "history_retention", kind: .enumeration, summary: "How long History keeps transcripts.",
                  defaultValue: .string("Month"), allowedValues: androidHistoryRetentions),
            Field(key: "keepRecordingsInHistory", kind: .boolean,
                  summary: "Keep finished cloud recordings in History to play back or transcribe again.",
                  defaultValue: .bool(false))
        ] + androidAudioFields + androidAppearanceFields
    }()

    private static let androidAudioFields: [Field] = [
        Field(key: "silenceDetectionEnabled", kind: .boolean, summary: "Stop a cloud recording after silence.",
              defaultValue: .bool(false)),
        Field(key: "silenceThreshold", kind: .number, summary: "Level below which audio counts as silence.",
              defaultValue: .double(DictationSilencePolicy.defaultThreshold),
              range: DictationSilencePolicy.thresholdRange),
        Field(key: "silenceDuration", kind: .number, summary: "Seconds of silence before stopping.",
              defaultValue: .double(DictationSilencePolicy.defaultDuration),
              range: DictationSilencePolicy.durationRange),
        Field(key: "autoCorrectionsEnabled", kind: .boolean,
              summary: "Learn corrections from edits to text the keyboard inserted.",
              defaultValue: .bool(AutoCorrectionLearningPolicy.enabledByDefault)),
        Field(key: "autoCorrectionsPromotionThreshold", kind: .integer,
              summary: "Edits before a correction is learned.",
              defaultValue: .int(AutoCorrectionLearningPolicy.defaultPromotionThreshold),
              range: AutoCorrectionLearningPolicy.numericPromotionThresholdRange),
        Field(key: "recordingSoundsEnabled", kind: .boolean, summary: "Play start and stop sounds.",
              defaultValue: .bool(RecordingFeedbackDefaults.enabled)),
        Field(key: "recordingSoundProfile", kind: .enumeration, summary: "Start and stop sound set.",
              defaultValue: .string(RecordingFeedbackDefaults.profile.rawValue),
              allowedValues: RecordingFeedbackProfile.allCases.map(\.rawValue)),
        Field(key: "recordingSoundVolume", kind: .number, summary: "Start and stop sound volume.",
              defaultValue: .double(RecordingFeedbackDefaults.volume), range: RecordingFeedbackDefaults.volumeRange)
    ]

    private static let androidAppearanceFields: [Field] = [
        Field(key: "appearance", kind: .enumeration, summary: "Light, dark or follow the phone.",
              defaultValue: .string("system"), allowedValues: ["system", "light", "dark"]),
        Field(key: "dynamicColor", kind: .boolean,
              summary: "Use wallpaper colours instead of the app's palette (Android 12 and later).",
              defaultValue: .bool(false))
    ]
}

/// The Android raw-configuration schema as JSON, so the app validates documents
/// against SpeakCore's definition instead of a copy. `SettingsSchemaAndroidExportTests`
/// fails when the committed asset is stale; regenerate it with `scripts/update-android-assets`.
public enum SettingsSchemaAndroidExport {
    public static func json() throws -> Data {
        let fields = SettingsSchema.fields(for: .android)
        let ownKeys = Set(fields.map(\.key))
        let document: AnyCodable.JSONValue = .object([
            "schemaVersion": .int(SettingsSchema.version),
            "platform": .string(SettingsSchemaPlatform.android.rawValue),
            "fields": .array(fields.map { field in
                guard case .object(var info) = field.schemaDescription else { return field.schemaDescription }
                info["key"] = .string(field.key)
                info.removeValue(forKey: "platforms")
                return .object(info)
            }),
            // Keys other platforms own: a document keeps them with a warning instead of an error.
            "otherPlatformKeys": .array(SettingsSchema.knownKeys.subtracting(ownKeys).sorted().map { .string($0) })
        ])
        var data = try SettingsDocument.encode(document)
        data.append(0x0A)
        return data
    }
}
