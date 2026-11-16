import Foundation

// The iPhone's persisted settings, keyed by `AppSettings` (SpeakiOS) property
// name, plus the Read aloud settings in `IOSVoiceOutputSettings`, whose
// `sonioxRegion` uses the Mac's `sonioxTTSRegion` key. API keys are never part
// of a document. SpeakiOS tests fail when a persisted setting has no field
// here, a default differs from a fresh install or an app enum's cases drift
// from `allowedValues`.
extension SettingsSchema {
    private typealias Field = SettingsSchemaField

    /// Values of SpeakiOS's `IOSTranscriptionMode`.
    static let iOSTranscriptionModes = ["streaming", "batch"]
    /// Values of SpeakiOS's `HardwareTriggerDestination`.
    static let iOSHardwareTriggerDestinations = ["auto", "clipboard", "clipboardAndPostProcess", "historyOnly"]
    /// Seconds of SpeakiOS's `TranscriptClipboardLifetime`; the default is five minutes.
    public static let iOSTranscriptClipboardLifetimes = [60, 300, 900]

    static let iOSFields: [SettingsSchemaField] = {
        typealias Shared = SharedApplicationPreferences
        let transcription: [Field] = [
            Field(key: "transcriptionMode", kind: .enumeration, summary: "Streaming or batch transcription.",
                  defaultValue: .string("streaming"), allowedValues: iOSTranscriptionModes),
            Field(key: "rememberedRemoteTranscriptionMode", kind: .enumeration,
                  summary: "Remote mode restored when leaving on-device transcription.",
                  defaultValue: nil, allowedValues: iOSTranscriptionModes),
            Field(key: "selectedModel", kind: .string, summary: "Model used for live (streaming) transcription.",
                  defaultValue: .string(Shared.liveTranscriptionModel.iOS.defaultValue),
                  modelCatalogue: .liveTranscription),
            Field(key: "batchTranscriptionModel", kind: .string, summary: "Model used for batch transcription.",
                  defaultValue: .string(Shared.batchTranscriptionModel.iOS.defaultValue),
                  modelCatalogue: .batchTranscription),
            Field(key: "preferredLocaleIdentifier", kind: .string, summary: "Spoken language hint, or automatic.",
                  defaultValue: .string(Shared.preferredLocale.iOS.defaultValue)),
            Field(key: "transcriptionKeywords", kind: .string,
                  summary: "Comma-separated words every provider biases towards.", defaultValue: .string("")),
            Field(key: "upgradeOfflineTranscriptsWhenOnline", kind: .boolean,
                  summary: "Re-transcribe offline captures with the cloud batch model when online.",
                  defaultValue: .bool(false)),
            Field(key: "keepAudioOnCancel", kind: .boolean,
                  summary: "Keep a cancelled recording's audio in Saved Recordings.",
                  defaultValue: .bool(Shared.keepAudioOnCancel.iOS.defaultValue)),
            Field(key: "preferredAudioInputUID", kind: .optionalString,
                  summary: "Microphone device ID, or null for the system default.", defaultValue: .null)
        ]
        let recording: [Field] = [
            Field(key: "visualDensity", kind: .enumeration, summary: "Normal or compact layout.",
                  defaultValue: .string(Shared.visualDensity.iOS.defaultValue.rawValue),
                  allowedValues: AppVisualDensity.allCases.map(\.rawValue)),
            Field(key: "autoStartRecording", kind: .boolean, summary: "Start recording when the app opens.",
                  defaultValue: .bool(false)),
            Field(key: "handsFreeDictationEnabled", kind: .boolean, summary: "Speech starts and stops recording.",
                  defaultValue: .bool(Shared.handsFreeDictationEnabled.iOS.defaultValue)),
            Field(key: "liveActivitiesEnabled", kind: .boolean, summary: "Show recordings as a Live Activity.",
                  defaultValue: .bool(true)),
            Field(key: "transcriptReadyNotificationsEnabled", kind: .boolean,
                  summary: "Notify when a background transcript is ready. Needs notification permission.",
                  defaultValue: .bool(false), isReadOnly: true),
            Field(key: "hardwareTriggerDestination", kind: .enumeration,
                  summary: "Where an Action Button, Siri or Shortcuts transcript goes.",
                  defaultValue: .string("auto"), allowedValues: iOSHardwareTriggerDestinations),
            Field(key: "autoStopOnSilenceEnabled", kind: .boolean,
                  summary: "Finish a headless capture after a run of silence.", defaultValue: .bool(false)),
            Field(key: "autoStopSilenceSeconds", kind: .number, summary: "Seconds of silence before it finishes.",
                  defaultValue: .double(3), range: 2...8),
            Field(key: "transcriptClipboardLifetime", kind: .integer,
                  summary: "Seconds a copied transcript stays on the clipboard: 60, 300 or 900.",
                  defaultValue: .int(300), range: 60...900),
            Field(key: "transcriptAllowsUniversalClipboard", kind: .boolean,
                  summary: "Let copied transcripts reach your other devices.", defaultValue: .bool(false))
        ]
        let cleanup: [Field] = [
            Field(key: "postProcessingEnabled", kind: .boolean, summary: "Clean up transcripts with a language model.",
                  defaultValue: .bool(Shared.postProcessingEnabled.iOS.defaultValue)),
            Field(key: "postProcessingModel", kind: .string, summary: "Model used for cleanup.",
                  defaultValue: .string(Shared.postProcessingModel.iOS.defaultValue),
                  modelCatalogue: .postProcessing),
            Field(key: "cleanupModelDiscoveryEnabled", kind: .boolean,
                  summary: "Offer every OpenRouter cleanup model.",
                  defaultValue: .bool(Shared.cleanupModelDiscoveryEnabled.iOS.defaultValue)),
            Field(key: "autoPostProcess", kind: .boolean, summary: "Clean up every transcript automatically.",
                  defaultValue: .bool(false))
        ]
        // Learned from edits to keyboard-inserted transcripts (#1651).
        let learnedCorrections: [Field] = [
            Field(key: "autoCorrectionsEnabled", kind: .boolean, summary: "Learn corrections from your edits.",
                  defaultValue: .bool(AutoCorrectionLearningPolicy.enabledByDefault)),
            Field(key: "autoCorrectionsPromotionThreshold", kind: .integer,
                  summary: "Edits before a correction is learned.",
                  defaultValue: .int(AutoCorrectionLearningPolicy.defaultPromotionThreshold),
                  range: AutoCorrectionLearningPolicy.numericPromotionThresholdRange)
        ]
        return transcription + recording + cleanup + learnedCorrections + iOSReadAloudFields
    }()

    /// SpeakiOS's `IOSVoiceOutputSettings`. The provider, model, voice and speed
    /// must form a selection `VoiceOutputProvider.selectionProblems` accepts.
    private static let iOSReadAloudFields: [Field] = [
        Field(key: "ttsProvider", kind: .enumeration, summary: "Read aloud provider.",
              defaultValue: .string(VoiceOutputProvider.defaultProvider.rawValue),
              allowedValues: VoiceOutputProvider.allCases.map(\.rawValue)),
        Field(key: "ttsModel", kind: .string,
              summary: "Read aloud model for the provider (an OpenRouter speech selection for OpenRouter).",
              defaultValue: .string(VoiceOutputProvider.defaultSelection.model)),
        Field(key: "ttsVoice", kind: .string,
              summary: "Read aloud voice for the model (soniox/<voice> for Soniox).",
              defaultValue: .string(VoiceOutputProvider.defaultSelection.voice)),
        ttsSpeedField,
        ttsLanguageIdentifierField,
        sonioxTTSRegionField
    ]
}
