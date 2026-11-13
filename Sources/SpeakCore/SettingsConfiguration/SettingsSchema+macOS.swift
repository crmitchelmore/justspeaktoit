import Foundation

// The Mac's persisted settings, keyed by `AppSettings` property name. The
// SpeakApp coverage tests fail when a persisted setting has no field here, when
// a default here differs from a fresh install, or when an app enum's cases
// drift from `allowedValues`.
extension SettingsSchema {
    private typealias Field = SettingsSchemaField

    static let macOSFields: [SettingsSchemaField] = {
        // Appended in groups: one long array literal exceeds the type checker's time limit.
        var fields = appearanceFields
        fields += transcriptionFields
        fields += postProcessingFields
        fields += dictationFields
        fields += feedbackFields
        fields += voiceOutputFields
        fields += integrationFields
        return fields
    }()

    private static func names<Choice: RawRepresentable & CaseIterable>(_: Choice.Type) -> [String]
    where Choice.RawValue == String {
        Choice.allCases.map(\.rawValue)
    }

    private static let appearanceFields: [Field] = [
        Field(key: "appearance", kind: .enumeration, summary: "Light, dark or follow the system.",
              defaultValue: .string("system"), allowedValues: ["system", "light", "dark"]),
        Field(key: "appVisibility", kind: .enumeration, summary: "Show the app in the Dock, the menu bar or both.",
              defaultValue: .string("dockAndMenuBar"), allowedValues: ["dockAndMenuBar", "menuBarOnly", "dockOnly"]),
        Field(key: "showStatusBarIconInDockOnly", kind: .boolean,
              summary: "Keep the menu bar icon while the app is Dock only.", defaultValue: .bool(true)),
        Field(key: "compactStatusBarIcon", kind: .boolean, summary: "Icon-only menu bar item.",
              defaultValue: .bool(false)),
        Field(key: "runAtLogin", kind: .boolean, summary: "Open the app when you log in.", defaultValue: .bool(false)),
        Field(key: "visualDensity", kind: .enumeration, summary: "Normal or compact layout.",
              defaultValue: .string(AppVisualDensity.normal.rawValue), allowedValues: names(AppVisualDensity.self)),
        Field(key: "showSidebarShortcutHints", kind: .boolean, summary: "Show keyboard shortcuts in the sidebar.",
              defaultValue: .bool(true)),
        Field(key: "recordingsDirectory", kind: .string, summary: "Folder that holds recordings (absolute path).",
              defaultValue: nil),
        Field(key: "analyticsEnabled", kind: .boolean,
              summary: "Anonymous product analytics. Consent is only given in Settings.",
              defaultValue: .bool(false), isReadOnly: true)
    ]

    private static let transcriptionFields: [Field] = [
        Field(key: "transcriptionMode", kind: .enumeration, summary: "Live streaming, remote batch or local model.",
              defaultValue: .string("liveNative"), allowedValues: ["liveNative", "batchRemote", "localModel"]),
        Field(key: "liveTranscriptionModel", kind: .string, summary: "Model used for live (streaming) transcription.",
              defaultValue: nil, modelCatalogue: .liveTranscription),
        Field(key: "batchTranscriptionModel", kind: .string, summary: "Model used for batch transcription.",
              defaultValue: .string(ModelCatalog.normalizedBatchTranscriptionModel(nil)),
              modelCatalogue: .batchTranscription),
        Field(key: "localTranscriptionMode", kind: .enumeration,
              summary: "Downloaded models run in batch or streaming.",
              defaultValue: .string("batch"), allowedValues: ["batch", "streaming"]),
        Field(key: "localTranscriptionModel", kind: .string, summary: "Downloaded local transcription model.",
              defaultValue: .string("local/whisperkit/tiny"), modelCatalogue: .localTranscription),
        Field(key: "rememberedLocalTranscriptionSource", kind: .enumeration,
              summary: "Local source restored when switching back to Local.",
              defaultValue: .string("apple"), allowedValues: ["apple", "downloaded"]),
        Field(key: "rememberedRemoteTranscriptionMode", kind: .enumeration,
              summary: "Remote mode restored when switching back to Remote.",
              defaultValue: .string("streaming"), allowedValues: ["streaming", "batch"]),
        Field(key: "preferredLocaleIdentifier", kind: .string, summary: "Spoken language hint, or automatic.",
              defaultValue: .string(TranscriptionLanguageCatalog.normalizedIdentifier(nil))),
        Field(key: "preferredAudioInputUID", kind: .optionalString,
              summary: "Microphone device ID, or null for default.",
              defaultValue: .null),
        Field(key: "transcriptionKeywords", kind: .string,
              summary: "Comma-separated words every provider biases towards.", defaultValue: .string("")),
        Field(key: "assemblyAIIgnoredPronunciationTerms", kind: .stringArray,
              summary: "Keyterms not sent to AssemblyAI.", defaultValue: .array([])),
        Field(key: "modulateSpeakerDiarizationEnabled", kind: .boolean, summary: "Modulate speaker labels.",
              defaultValue: .bool(true)),
        Field(key: "modulateEmotionSignalEnabled", kind: .boolean, summary: "Modulate emotion signal.",
              defaultValue: .bool(false)),
        Field(key: "modulateAccentSignalEnabled", kind: .boolean, summary: "Modulate accent signal.",
              defaultValue: .bool(false)),
        Field(key: "modulatePIIPhiTaggingEnabled", kind: .boolean, summary: "Modulate PII/PHI tagging.",
              defaultValue: .bool(false)),
        Field(key: "postRecordingTailDuration", kind: .number, summary: "Seconds recorded after you stop.",
              defaultValue: .double(SpeechDefaults.recordingTailDuration), range: 0...2),
        Field(key: "liveStopGracePeriod", kind: .number, summary: "Extra seconds a live stream waits after stop.",
              defaultValue: .double(SpeechDefaults.liveStopGracePeriod), range: 0...2),
        Field(key: "connectionPreWarmingEnabled", kind: .boolean, summary: "Pre-warm provider connections while idle.",
              defaultValue: .bool(SpeechDefaults.connectionPreWarmingEnabled)),
        Field(key: "audioPreWarmingEnabled", kind: .boolean, summary: "Prepare the recorder while idle.",
              defaultValue: .bool(true)),
        Field(key: "warmMicrophoneOnKeyPress", kind: .boolean, summary: "Open the microphone on hotkey press.",
              defaultValue: .bool(true)),
        Field(key: "speedMode", kind: .enumeration, summary: "Instant, or Auto-Clean (live polish while dictating).",
              defaultValue: .string(SpeedModeID.instant.rawValue), allowedValues: names(SpeedModeID.self))
    ]

    private static let postProcessingFields: [Field] = [
        Field(key: "postProcessingEnabled", kind: .boolean, summary: "Clean up transcripts with a language model.",
              defaultValue: .bool(SharedApplicationPreferences.postProcessingEnabled.macOS.defaultValue)),
        Field(key: "postProcessingModel", kind: .string, summary: "Model used for cleanup.",
              defaultValue: .string(ModelCatalog.normalizedPostProcessingModel(nil)),
              modelCatalogue: .postProcessing),
        Field(key: "cleanupModelDiscoveryEnabled", kind: .boolean, summary: "Offer every OpenRouter cleanup model.",
              defaultValue: .bool(false)),
        Field(key: "postProcessingTemperature", kind: .number, summary: "Cleanup model temperature.",
              defaultValue: .double(SpeechDefaults.temperature), range: 0...1),
        Field(key: "postProcessingOutputLanguage", kind: .string, summary: "Language cleanup writes in.",
              defaultValue: .string(SpeechDefaults.outputLanguage)),
        Field(key: "postProcessingIncludeLexiconDirectives", kind: .boolean,
              summary: "Send lexicon directives to cleanup.", defaultValue: .bool(true)),
        Field(key: "postProcessingIncludeContextTags", kind: .boolean, summary: "Send app context tags to cleanup.",
              defaultValue: .bool(true)),
        Field(key: "postProcessingStreamingEnabled", kind: .boolean, summary: "Stream cleanup output.",
              defaultValue: .bool(SpeechDefaults.postProcessingStreamingEnabled)),
        Field(key: "livePolishModel", kind: .string, summary: "Auto-Clean model; empty uses the fast default.",
              defaultValue: .string(""), modelCatalogue: .livePolish),
        Field(key: "livePolishDebounceMs", kind: .integer, summary: "Auto-Clean debounce in milliseconds.",
              defaultValue: .int(LivePolishPolicy.debounceMilliseconds), range: 0...60_000),
        Field(key: "livePolishMinDeltaChars", kind: .integer, summary: "Characters of new text before Auto-Clean runs.",
              defaultValue: .int(LivePolishPolicy.minimumDeltaCharacters), range: 0...65_535),
        Field(key: "livePolishTailWindowChars", kind: .integer, summary: "Characters Auto-Clean may rewrite.",
              defaultValue: .int(LivePolishPolicy.tailWindowCharacters), range: 0...65_535),
        Field(key: "skipPostProcessingWithLivePolish", kind: .boolean, summary: "Skip cleanup after Auto-Clean.",
              defaultValue: .bool(LivePolishPolicy.skipPostProcessing))
    ]

    private static let dictationFields: [Field] = [
        Field(key: "selectedHotKey", kind: .object, summary: "Dictation hotkey. Record it in Keyboard settings.",
              defaultValue: nil, isReadOnly: true),
        Field(key: "hotKeyActivationStyle", kind: .enumeration, summary: "Hold, double-tap, or both.",
              defaultValue: .string("holdAndDoubleTap"),
              allowedValues: ["holdToRecord", "doubleTapToggle", "holdAndDoubleTap"]),
        Field(key: "holdThreshold", kind: .number, summary: "Seconds a press must last to count as a hold.",
              defaultValue: .double(0.35), range: 0.2...1.5),
        Field(key: "doubleTapWindow", kind: .number, summary: "Seconds allowed between double-tap presses.",
              defaultValue: .double(0.4), range: 0.2...1.0),
        Field(key: "handsFreeDictationEnabled", kind: .boolean, summary: "Speech starts and stops recording.",
              defaultValue: .bool(false)),
        Field(key: "silenceDetectionEnabled", kind: .boolean, summary: "Stop recording after silence.",
              defaultValue: .bool(false)),
        Field(key: "silenceThreshold", kind: .number, summary: "Level below which audio counts as silence.",
              defaultValue: .double(DictationSilencePolicy.defaultThreshold),
              range: DictationSilencePolicy.thresholdRange),
        Field(key: "silenceDuration", kind: .number, summary: "Seconds of silence before stopping.",
              defaultValue: .double(DictationSilencePolicy.defaultDuration),
              range: DictationSilencePolicy.durationRange),
        Field(key: "historyFlushInterval", kind: .number, summary: "Seconds between History saves.",
              defaultValue: .double(5), range: 1...30),
        Field(key: "voiceCommandsEnabled", kind: .boolean, summary: "Recognise spoken editing commands.",
              defaultValue: .bool(SpeechDefaults.voiceCommandsEnabled)),
        Field(key: "clipboardInsertionTriggers", kind: .string, summary: "Apps that always use the clipboard.",
              defaultValue: .string(SpeechDefaults.clipboardInsertionTriggers)),
        Field(key: "autoCorrectionsEnabled", kind: .boolean, summary: "Learn corrections from your edits.",
              defaultValue: .bool(AutoCorrectionLearningPolicy.enabledByDefault)),
        Field(key: "autoCorrectionsPromotionThreshold", kind: .integer,
              summary: "Edits before a correction is learned.",
              defaultValue: .int(AutoCorrectionLearningPolicy.defaultPromotionThreshold),
              range: AutoCorrectionLearningPolicy.numericPromotionThresholdRange),
        Field(key: "keepAudioOnCancel", kind: .boolean, summary: "Keep a cancelled recording's audio in History.",
              defaultValue: .bool(SpeechDefaults.keepAudioOnCancel)),
        Field(key: "cancelRecordingOnEscape", kind: .boolean, summary: "Escape cancels recording.",
              defaultValue: .bool(SpeechDefaults.cancelRecordingOnEscape)),
        Field(key: "textOutputMethod", kind: .enumeration, summary: "How transcripts reach the focused app.",
              defaultValue: .string("clipboardOnly"), allowedValues: ["smart", "accessibilityOnly", "clipboardOnly"]),
        Field(key: "accessibilityInsertionMode", kind: .enumeration,
              summary: "Insert at the cursor or replace the field.",
              defaultValue: .string("insertAtCursor"), allowedValues: ["insertAtCursor", "replaceAll"]),
        Field(key: "restoreClipboardAfterPaste", kind: .boolean, summary: "Put the clipboard back after pasting.",
              defaultValue: .bool(true)),
        Field(key: "appSwitchDelivery", kind: .enumeration, summary: "Where a transcript goes after you switch apps.",
              defaultValue: .string(AppSwitchDelivery.defaultValue.rawValue),
              allowedValues: names(AppSwitchDelivery.self)),
        Field(key: "streamingInsertionEnabled", kind: .boolean, summary: "Experimental: type while dictating.",
              defaultValue: .bool(false))
    ]

    private static let feedbackFields: [Field] = [
        Field(key: "showHUDDuringSessions", kind: .boolean, summary: "Show the recording HUD.",
              defaultValue: .bool(SpeechDefaults.showHUD)),
        Field(key: "showLiveTranscriptInHUD", kind: .boolean, summary: "Show live text in the HUD.",
              defaultValue: .bool(SpeechDefaults.liveTranscriptHUD)),
        Field(key: "showCompactHUD", kind: .boolean,
              summary: "Compact HUD.", defaultValue: .bool(SpeechDefaults.compactHUD)),
        Field(key: "shortenErrorDisplay", kind: .boolean, summary: "Shorter error messages.",
              defaultValue: .bool(SpeechDefaults.shortErrors)),
        Field(key: "hudSizePreference", kind: .enumeration, summary: "HUD size.",
              defaultValue: .string(HUDExpansionPreference.defaultValue.rawValue),
              allowedValues: names(HUDExpansionPreference.self)),
        Field(key: "recordingSoundsEnabled", kind: .boolean, summary: "Play start and stop sounds.",
              defaultValue: .bool(RecordingFeedbackDefaults.enabled)),
        Field(key: "recordingSoundProfile", kind: .enumeration, summary: "Start and stop sound set.",
              defaultValue: .string(RecordingFeedbackDefaults.profile.rawValue),
              allowedValues: names(RecordingFeedbackProfile.self)),
        Field(key: "recordingSoundVolume", kind: .number, summary: "Start and stop sound volume.",
              defaultValue: .double(RecordingFeedbackDefaults.volume), range: 0.02...1)
    ]

    private static let voiceOutputFields: [Field] = [
        Field(key: "defaultTTSVoice", kind: .string, summary: "Voice used to speak text (provider/voice).",
              defaultValue: .string("openai/alloy")),
        Field(key: "ttsLanguageIdentifier", kind: .string, summary: "Voice language, or automatic.",
              defaultValue: .string(VoiceOutputLanguageCatalog.normalizedIdentifier(nil))),
        Field(key: "mistralTTSModel", kind: .enumeration, summary: "Mistral speech model.",
              defaultValue: .string(MistralTTSCatalog.defaultModel.rawValue),
              allowedValues: names(MistralTTSModel.self)),
        Field(key: "sonioxTTSRegion", kind: .enumeration, summary: "Soniox speech region.",
              defaultValue: .string(SonioxTTSRegion.migrated(from: nil).rawValue),
              allowedValues: names(SonioxTTSRegion.self)),
        Field(key: "ttsSpeed", kind: .number, summary: "Speaking rate; 1 is normal.", defaultValue: .double(1),
              range: 0.5...2),
        Field(key: "ttsPitch", kind: .number,
              summary: "Pitch in semitones.", defaultValue: .double(0), range: -12...12),
        Field(key: "ttsQuality", kind: .enumeration, summary: "Speech quality.",
              defaultValue: .string(VoiceSynthesisQuality.high.rawValue),
              allowedValues: names(VoiceSynthesisQuality.self)),
        Field(key: "ttsOutputFormat", kind: .enumeration, summary: "Saved audio format.",
              defaultValue: .string(VoiceAudioFormat.macDefault.rawValue), allowedValues: names(VoiceAudioFormat.self)),
        Field(key: "ttsAutoPlay", kind: .boolean, summary: "Play generated speech automatically.",
              defaultValue: .bool(SpeechGenerationDefaults.autoPlay)),
        Field(key: "ttsSaveToDirectory", kind: .boolean, summary: "Save generated speech to the recordings folder.",
              defaultValue: .bool(SpeechGenerationDefaults.saveToRecordings)),
        Field(key: "ttsUseSSML", kind: .boolean, summary: "Send SSML markup to voices that accept it.",
              defaultValue: .bool(false)),
        Field(key: "ttsFavoriteVoices", kind: .stringArray, summary: "Favourite voice IDs.", defaultValue: .array([])),
        Field(key: "ttsPronunciationDictionary", kind: .stringMap, summary: "Word to phonetic spelling.",
              defaultValue: .object([:]))
    ]

    private static let integrationFields: [Field] = [
        Field(key: "paidAccessRoutingEnabled", kind: .boolean, summary: "Route through the paid subscription.",
              defaultValue: .bool(false)),
        Field(key: "simpleModelChoices", kind: .boolean, summary: "Let the subscription choose models.",
              defaultValue: .bool(false)),
        Field(key: "enableSendToMac", kind: .boolean, summary: "Receive transcripts from iPhone and Watch.",
              defaultValue: .bool(false)),
        Field(key: "pasteRemoteTranscriptsAtCursor", kind: .boolean, summary: "Paste phone transcripts at the cursor.",
              defaultValue: .bool(false)),
        Field(key: "enableAutomationServer", kind: .boolean,
              summary: "Local automation socket for the speak CLI and MCP. Change it in Settings.",
              defaultValue: .bool(false), isReadOnly: true),
        Field(key: "allowAutomationConfigurationChanges", kind: .boolean,
              summary: "Let automation clients change settings. Change it in Settings.",
              defaultValue: .bool(false), isReadOnly: true)
    ]
}
