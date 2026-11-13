import Foundation

// The canonical portable preference catalogue: each field's key, title,
// group, kind and default. Feature-owned field groups (shell, Soniox voice,
// capture delivery, live polish, Modulate) are appended in `fields`.
extension DesktopConfiguration {
    public enum Kind: Sendable {
        case text
        case boolean
        case number(ClosedRange<Double>)
        case choice([Choice])
    }

    public struct Choice: Sendable {
        public let value: String
        public let title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public struct Field: Sendable {
        public let key: String
        public let title: String
        public let group: String
        public let kind: Kind
        public let defaultValue: AnyCodable
        public internal(set) var requiresHUDOverlay = false
        public internal(set) var requiresHandsFreeGuard = false
        public internal(set) var enabledBy: String?

        public var serializedChoices: String? {
            guard case .choice(let choices) = kind else { return nil }
            return choices.map { "\($0.value)\t\($0.title)" }.joined(separator: "\n")
        }
    }

    public static let fields: [Field] = {
        // Appended step by step: one chained `+` expression exceeds the type checker's time limit.
        var all = Self.baseFields
        all += [Self.automationConfigurationChangesField]
        all += [.init(key: CleanupModelSelection.preferenceKey,
                      title: CleanupModelSelection.settingTitle + " (metadata only; refresh on Apply)",
                      group: "Post-processing", kind: .boolean, defaultValue: AnyCodable(.bool(false)))]
        all += [VoiceSynthesisPreference.quality.field, VoiceAudioFormat.transferField]
        all += ShellPreference.fields
        all += SonioxVoicePreference.fields
        all += CaptureDeliveryPreference.fields
        all += LivePolishPreference.fields
        all += Self.modulateFields
        return all
    }()

    /// The local grant `speak config set` and MCP `set_configuration` need. File
    /// imports keep the current value, and automation can never change it.
    public static let automationConfigurationChangesField = Field(
        key: ApplicationPreferenceKey.allowAutomationConfigurationChanges.rawValue,
        title: "Allow automation to change settings (speak config set and MCP set_configuration)",
        group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(false)))

    private static let baseFields: [Field] = [
        .init(key: AppSwitchDelivery.preferenceKey, title: AppSwitchDelivery.settingName,
              group: "Output", kind: .choice(AppSwitchDelivery.desktopChoices),
              defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue,
              title: "Learn corrections (verified inserted text; local approval required)",
              group: "Corrections", kind: .boolean,
              defaultValue: AnyCodable(.bool(AutoCorrectionLearningPolicy.enabledByDefault))),
        .init(key: ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue,
              title: "Promote a repeated correction after occurrences (2 to 10)",
              group: "Corrections", kind: .number(AutoCorrectionLearningPolicy.numericPromotionThresholdRange),
              defaultValue: AnyCodable(.double(Double(AutoCorrectionLearningPolicy.defaultPromotionThreshold)))),
        .init(key: ApplicationPreferenceKey.visualDensity.rawValue, title: "Layout Density",
              group: "General", kind: .choice(AppVisualDensity.allCases.map {
                  Choice(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(AppVisualDensity.normal.rawValue))),
        .init(key: ApplicationPreferenceKey.preferredLocale.rawValue,
              title: "Spoken language (automatic or locale, e.g. en_GB)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string("automatic"))),
        .init(key: ApplicationPreferenceKey.transcriptionKeywords.rawValue,
              title: "Shared keywords (comma-separated; supported providers only)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.assemblyAIKeyterms.rawValue,
              title: "AssemblyAI keyterms (includes pronunciation hints when selected)",
              group: "Transcription", kind: .text, defaultValue: AnyCodable(.string(""))),
        .init(key: ApplicationPreferenceKey.liveStopGracePeriod.rawValue,
              title: "Live stop grace (seconds; supported providers)",
              group: "Transcription", kind: .number(0...2),
              defaultValue: AnyCodable(.double(SpeechDefaults.liveStopGracePeriod))),
        .init(key: ApplicationPreferenceKey.handsFreeDictationEnabled.rawValue,
              title: "Hands-free: hotkey arms sound activation (noise can trigger)",
              group: "Transcription", kind: .boolean, defaultValue: AnyCodable(.bool(false)),
              requiresHandsFreeGuard: true),
        .init(key: ApplicationPreferenceKey.silenceDetectionEnabled.rawValue,
              title: "Auto-stop manual recording on silence",
              group: "Transcription", kind: .boolean, defaultValue: AnyCodable(.bool(false))),
        .init(key: ApplicationPreferenceKey.silenceThreshold.rawValue,
              title: "Silence threshold (0.01 to 0.2; lower is more sensitive)",
              group: "Transcription", kind: .number(DictationSilencePolicy.thresholdRange),
              defaultValue: AnyCodable(.double(DictationSilencePolicy.defaultThreshold))),
        .init(key: ApplicationPreferenceKey.silenceDuration.rawValue,
              title: "Silence duration (seconds; manual and hands-free)",
              group: "Transcription", kind: .number(DictationSilencePolicy.durationRange),
              defaultValue: AnyCodable(.double(DictationSilencePolicy.defaultDuration))),
        .init(key: ApplicationPreferenceKey.postProcessingTemperature.rawValue, title: "Temperature (0 to 1)",
              group: "Post-processing", kind: .number(0...1),
              defaultValue: AnyCodable(.double(SpeechDefaults.temperature))),
        .init(key: ApplicationPreferenceKey.postProcessingStreamingEnabled.rawValue,
              title: "Stream remote cleanup previews (local cleanup is completed-only)",
              group: "Post-processing", kind: .boolean,
              defaultValue: AnyCodable(.bool(SpeechDefaults.postProcessingStreamingEnabled))),
        .init(key: DesktopConnectionPreWarming.preferenceKey,
              title: "Prepare completed-only OpenRouter cleanup (not live/streaming)",
              group: "Post-processing", kind: .boolean,
              defaultValue: AnyCodable(.bool(SpeechDefaults.connectionPreWarmingEnabled))),
        .init(key: DesktopConnectionPreWarming.approvalProjectionKey,
              title: "Approve probes this session, only after successful capture",
              group: "Post-processing", kind: .boolean, defaultValue: AnyCodable(.bool(false)),
              enabledBy: DesktopConnectionPreWarming.preferenceKey),
        .init(key: ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue,
              title: "Output language (blank keeps the transcript language)",
              group: "Post-processing", kind: .text,
              defaultValue: AnyCodable(.string(SpeechDefaults.outputLanguage))),
        .init(key: ApplicationPreferenceKey.holdThreshold.rawValue, title: "Hold threshold (seconds)",
              group: "Keyboard", kind: .number(0.2...1.5),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultHoldThreshold))),
        .init(key: ApplicationPreferenceKey.doubleTapWindow.rawValue, title: "Double-tap window (seconds)",
              group: "Keyboard", kind: .number(0.2...1),
              defaultValue: AnyCodable(.double(HotKeyGestureTiming.defaultDoubleTapWindow))),
        .init(key: ApplicationPreferenceKey.showHUD.rawValue, title: "Show recording HUD",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.showHUD))),
        .init(key: ApplicationPreferenceKey.showSidebarShortcutHints.rawValue, title: "Show sidebar shortcut hints",
              group: "General", kind: .boolean,
              defaultValue: AnyCodable(.bool(DesktopSidebarShortcut.showHintsByDefault))),
        .init(key: ApplicationPreferenceKey.voiceCommandsEnabled.rawValue, title: "Enable voice commands",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.voiceCommandsEnabled))),
        .init(key: ApplicationPreferenceKey.clipboardInsertionTriggers.rawValue,
              title: "Clipboard triggers (comma-separated; adds to built-in phrases)",
              group: "General", kind: .text,
              defaultValue: AnyCodable(.string(SpeechDefaults.clipboardInsertionTriggers)),
              enabledBy: ApplicationPreferenceKey.voiceCommandsEnabled.rawValue),
        .init(key: ApplicationPreferenceKey.showLiveTranscriptInHUD.rawValue, title: "Show live transcript in HUD",
              group: "General", kind: .boolean,
              defaultValue: AnyCodable(.bool(SpeechDefaults.liveTranscriptHUD)), requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.shortenErrorDisplay.rawValue,
              title: "Shorten HUD error display (3.6 seconds instead of 6)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.shortErrors)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.showCompactHUD.rawValue,
              title: "Show compact HUD (dot, level meter and timer)",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(SpeechDefaults.compactHUD)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.postRecordingTailDuration.rawValue,
              title: "Recording buffer (seconds after finishing)",
              group: "Transcription", kind: .number(0...2),
              defaultValue: AnyCodable(.double(SpeechDefaults.recordingTailDuration))),
        .init(key: ApplicationPreferenceKey.hudSizePreference.rawValue, title: "Full HUD size",
              group: "General", kind: .choice(HUDExpansionPreference.allCases.map {
                  Choice(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(HUDExpansionPreference.defaultValue.rawValue)),
              requiresHUDOverlay: true),
        .init(key: ApplicationPreferenceKey.recordingSoundsEnabled.rawValue,
              title: "Play recording start and stop sounds",
              group: "General", kind: .boolean, defaultValue: AnyCodable(.bool(RecordingFeedbackDefaults.enabled))),
        .init(key: ApplicationPreferenceKey.recordingSoundProfile.rawValue, title: "Recording sound profile",
              group: "General", kind: .choice(RecordingFeedbackProfile.allCases.map {
                  Choice(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(RecordingFeedbackDefaults.profile.rawValue))),
        .init(key: ApplicationPreferenceKey.recordingSoundVolume.rawValue, title: "Recording sound volume (0 to 1)",
              group: "General", kind: .number(0...1),
              defaultValue: AnyCodable(.double(RecordingFeedbackDefaults.volume)))
    ]
}
