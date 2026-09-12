import Foundation
import SpeakCore
import SpeakHotKeys

@MainActor
enum MigrationPreferenceSchema {
    static let booleans: Set<String> = [
        "analyticsEnabled",
        "audioPreWarmingEnabled",
        "autoCorrectionsEnabled",
        "compactStatusBarIcon",
        "connectionPreWarmingEnabled",
        "enableAutomationServer",
        "enableSendToMac",
        "handsFreeDictationEnabled",
        "hasAnsweredAnalyticsConsent",
        "hasCompletedOnboarding",
        "modulateAccentSignal",
        "modulateEmotionSignal",
        "modulatePIIPhiTagging",
        "modulateSpeakerDiarization",
        "postProcessingEnabled",
        "postProcessingIncludeContextTags",
        "postProcessingIncludeLexiconDirectives",
        "postProcessingStreamingEnabled",
        "recordingSoundsEnabled",
        "restoreClipboard",
        "runAtLogin",
        "shortenErrorDisplay",
        "showCompactHUD",
        "showHUD",
        "showLiveTranscriptInHUD",
        "showSidebarShortcutHints",
        "showStatusBarIconInDockOnly",
        "silenceDetectionEnabled",
        "skipPostProcessingWithLivePolish",
        "streamingInsertionEnabled",
        "ttsAutoPlay",
        "ttsSaveToDirectory",
        "ttsUseSSML",
        "voiceCommandsEnabled"
    ]
    static let numbers: Set<String> = [
        "autoCorrectionsPromotionThreshold",
        "deepgramStopGracePeriod",
        "doubleTapWindow",
        "historyFlushInterval",
        "holdThreshold",
        "livePolishDebounceMs",
        "livePolishMinDeltaChars",
        "livePolishTailWindowChars",
        "liveStopGracePeriod",
        "postProcessingTemperature",
        "postRecordingTailDuration",
        "recordingSoundVolume",
        "silenceDuration",
        "silenceThreshold",
        "ttsPitch",
        "ttsSpeed"
    ]
    static let arrays: Set<String> = [
        "assemblyAIIgnoredPronunciationTerms",
        "recoveredTranscriptionKeywords",
        "ttsFavoriteVoices"
    ]
    static let json: Set<String> = ["selectedHotKey", "customShortcutBindings", "ttsPronunciationDictionary"]
    static func validate(_ record: MigrationRecord) throws {
        if json.contains(record.id) {
            try validateJSON(record)
        } else {
            try validateScalar(record)
        }
    }
    private static func validateJSON(_ record: MigrationRecord) throws {
        let invalid = MigrationError.invalid("Invalid setting value")
        let key = record.id
        guard record.kind == "jsonDefault" else {
            throw invalid
        }
        switch key {
        case "selectedHotKey":
            _ = try MigrationCoding.decode(HotKey.self, record.value)
        case "customShortcutBindings":
            _ = try MigrationCoding.decode([ShortcutAction: KeyBinding].self, record.value)
        default: _ = try MigrationCoding.decode([String: String].self, record.value)
        }
    }
    private static func validateScalar(_ record: MigrationRecord) throws {
        let invalid = MigrationError.invalid("Invalid setting value")
        let key = record.id
        guard record.kind == "default" else {
            throw invalid
        }
        if booleans.contains(key) {
            guard case .bool = record.value.storage else {
                throw invalid
            }
        } else if numbers.contains(key) {
            try validateNumber(record)
        } else if arrays.contains(key) {
            _ = try MigrationCoding.decode([String].self, record.value)
        } else if key == "speakTransportPairedDevices" {
            _ = try MigrationCoding.decode([String: String].self, record.value)
        } else {
            guard case .string = record.value.storage else {
                throw invalid
            }
        }
    }
    private static func validateNumber(_ record: MigrationRecord) throws {
        let invalid = MigrationError.invalid("Invalid numeric preference")
        let key = record.id
        let number: Double
        switch record.value.storage {
        case .int(let value): number = Double(value)
        case .double(let value): number = value
        default: throw invalid
        }
        guard number.isFinite, abs(number) <= 1_000_000,
              key == "ttsPitch" || number >= 0 else {
            throw invalid
        }
    }
}
