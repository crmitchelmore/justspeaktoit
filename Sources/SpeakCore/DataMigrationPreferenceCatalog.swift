import Foundation

/// Archive acceptance metadata, not a declaration of executable host capabilities.
public enum DataMigrationPreferenceCatalog {
    public enum Kind: Equatable, Sendable {
        case boolean, number, text, stringArray, json, stringDictionary
    }

    public struct Definition: Sendable {
        public let key: String
        public let category: DataMigrationCategory
        public let kind: Kind

        public var recordKind: String { kind == .json ? "jsonDefault" : "default" }
    }

    public static let definitions: [Definition] = ApplicationPreferenceKey.allCases.compactMap { key in
        guard let kind = kind(for: key) else { return nil }
        return Definition(key: key.rawValue, category: category(for: key), kind: kind)
    } + [
        Definition(key: "customShortcutBindings", category: .settings, kind: .json),
        Definition(key: "rememberedOnDeviceLiveTranscriptionModel", category: .settings, kind: .text),
        Definition(key: "rememberedRemoteLiveTranscriptionModel", category: .settings, kind: .text),
        Definition(key: "hasCompletedOnboarding", category: .settings, kind: .boolean),
        Definition(key: "hasAnsweredAnalyticsConsent", category: .settings, kind: .boolean),
        Definition(key: "speakTransportPairingCode", category: .credentials, kind: .text),
        Definition(key: "speakTransportPairedDevices", category: .credentials, kind: .stringDictionary)
    ]

    private static let indexed = Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0) })

    public static func definition(for key: String) -> Definition? { indexed[key] }

    public static func category(for key: String) -> DataMigrationCategory? { indexed[key]?.category }

    public static func keys(in category: DataMigrationCategory) -> Set<String> {
        Set(definitions.filter { $0.category == category }.map(\.key))
    }

    public static func keys(ofKind kind: Kind) -> Set<String> {
        Set(definitions.filter { $0.kind == kind }.map(\.key))
    }

    public static func validate(
        _ record: DataMigrationRecord, category: DataMigrationCategory,
        validateJSON: (DataMigrationRecord) throws -> Void
    ) throws {
        guard let definition = indexed[record.id], definition.category == category else {
            throw DataMigrationError.invalid("Unknown setting")
        }
        guard record.kind == definition.recordKind else {
            throw DataMigrationError.invalid("Invalid setting value")
        }
        switch definition.kind {
        case .number:
            try validateNumber(record)
        case .json:
            try validateJSON(record)
        default:
            guard matches(record.value.storage, kind: definition.kind) else { throw invalidValue() }
        }
    }

    private static func invalidValue() -> DataMigrationError { .invalid("Invalid setting value") }

    private static func matches(_ value: AnyCodable.JSONValue, kind: Kind) -> Bool {
        switch (kind, value) {
        case (.boolean, .bool), (.text, .string):
            return true
        case (.stringArray, .array(let values)):
            return values.allSatisfy(isString)
        case (.stringDictionary, .object(let values)):
            return values.values.allSatisfy(isString)
        default:
            return false
        }
    }

    private static func isString(_ value: AnyCodable.JSONValue) -> Bool {
        if case .string = value { return true }
        return false
    }

    private static func validateNumber(_ record: DataMigrationRecord) throws {
        let number: Double
        switch record.value.storage {
        case .int(let value): number = Double(value)
        case .double(let value): number = value
        default: throw DataMigrationError.invalid("Invalid numeric preference")
        }
        guard number.isFinite, abs(number) <= 1_000_000,
              record.id == ApplicationPreferenceKey.ttsPitch.rawValue || number >= 0 else {
            throw DataMigrationError.invalid("Invalid numeric preference")
        }
    }

    private static func category(for key: ApplicationPreferenceKey) -> DataMigrationCategory {
        switch key {
        case .transcriptionKeywords, .assemblyAIKeyterms, .recoveredTranscriptionKeywords,
             .assemblyAIIgnoredPronunciationTerms, .ttsPronunciationDictionary:
            return .vocabulary
        case .enableSendToMac, .enableAutomationServer:
            return .connections
        default:
            return .settings
        }
    }

    private static func kind(for key: ApplicationPreferenceKey) -> Kind? {
        switch key {
        case .trackedKeyIdentifiers, .transcriptionKeywordsLastReconciled:
            return nil
        case .analyticsEnabled, .audioPreWarmingEnabled, .autoCorrectionsEnabled,
             .compactStatusBarIcon, .connectionPreWarmingEnabled, .enableAutomationServer,
             .enableSendToMac, .handsFreeDictationEnabled, .modulateAccentSignal,
             .modulateEmotionSignal, .modulatePIIPhiTagging, .modulateSpeakerDiarization,
             .paidAccessRoutingEnabled, .pasteRemoteTranscriptsAtCursor, .postProcessingEnabled,
             .postProcessingIncludeContextTags, .postProcessingIncludeLexiconDirectives,
             .postProcessingStreamingEnabled, .recordingSoundsEnabled, .restoreClipboard, .runAtLogin,
             .shortenErrorDisplay, .showCompactHUD, .showHUD, .showLiveTranscriptInHUD,
             .showSidebarShortcutHints, .showStatusBarIconInDockOnly, .silenceDetectionEnabled,
             .simpleModelChoices, .skipPostProcessingWithLivePolish, .streamingInsertionEnabled,
             .ttsAutoPlay, .ttsSaveToDirectory, .ttsUseSSML, .voiceCommandsEnabled, .warmMicrophoneOnKeyPress:
            return .boolean
        case .autoCorrectionsPromotionThreshold, .deepgramStopGracePeriod, .doubleTapWindow,
             .historyFlushInterval, .holdThreshold, .livePolishDebounceMs, .livePolishMinDeltaChars,
             .livePolishTailWindowChars, .liveStopGracePeriod, .postProcessingTemperature,
             .postRecordingTailDuration, .recordingSoundVolume, .silenceDuration, .silenceThreshold,
             .ttsPitch, .ttsSpeed:
            return .number
        case .assemblyAIIgnoredPronunciationTerms, .recoveredTranscriptionKeywords, .ttsFavoriteVoices:
            return .stringArray
        case .selectedHotKey, .ttsPronunciationDictionary:
            return .json
        case .appearance, .visualDensity, .transcriptionMode, .liveTranscriptionModel,
             .batchTranscriptionModel, .localTranscriptionModel, .localTranscriptionMode,
             .localStreamingModelSource, .postProcessingModel, .postProcessingOutputLanguage,
             .textOutputMethod, .appSwitchDelivery, .appVisibility, .recordingsDirectory,
             .hotKeyActivation, .preferredLocale, .preferredAudioInputUID, .defaultTTSVoice,
             .ttsLanguage, .sonioxTTSRegion, .ttsQuality, .ttsOutputFormat, .hudSizePreference,
             .speedMode, .livePolishModel, .clipboardInsertionTriggers, .recordingSoundProfile,
             .assemblyAIKeyterms, .transcriptionKeywords, .accessibilityInsertionMode,
             .rememberedLocalTranscriptionSource, .rememberedRemoteTranscriptionMode:
            return .text
        }
    }
}
