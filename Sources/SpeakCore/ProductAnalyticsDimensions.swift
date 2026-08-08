import Foundation

public enum AnalyticsPermissionType: String, Codable, Sendable {
    case microphone, speech, accessibility, notifications
    case localNetwork = "local_network"
}

public enum AnalyticsPermissionState: String, Codable, Sendable { case granted, denied, restricted }
public enum AnalyticsTranscriptionMode: String, Codable, Sendable { case live, batch }
public enum AnalyticsTriggerSource: String, Codable, Sendable {
    case hotkey, keyboard, widget
    case menuBar = "menu_bar"
    case actionButton = "action_button"
    case urlScheme = "url_scheme"
}

public enum AnalyticsDurationBucket: String, Codable, Sendable {
    case underFiveSeconds = "<5s"
    case fiveToFifteenSeconds = "5-15s"
    case fifteenToSixtySeconds = "15-60s"
    case oneToFiveMinutes = "1-5m"
    case overFiveMinutes = ">5m"
}

public enum AnalyticsWordCountBucket: String, Codable, Sendable {
    case oneToTen = "1-10"
    case elevenToFifty = "11-50"
    case fiftyOneToTwoHundred = "51-200"
    case twoHundredOneToThousand = "201-1000"
    case overThousand = ">1000"
}

public enum AnalyticsLatencyBucket: String, Codable, Sendable {
    case under250Milliseconds = "<250ms"
    case milliseconds250ToOneSecond = "250ms-1s"
    case oneToThreeSeconds = "1-3s"
    case threeToTenSeconds = "3-10s"
    case overTenSeconds = ">10s"
}

public enum AnalyticsOutputMethod: String, Codable, Sendable {
    case paste, clipboard, keyboard
    case sendToMac = "send_to_mac"
}

public enum AnalyticsPipelineStage: String, Codable, Sendable { case capture, stream, provider, output }
public enum AnalyticsErrorCategory: String, Codable, Sendable {
    case authentication, connectivity, permission, providerUnavailable = "provider_unavailable"
    case rateLimited = "rate_limited"
    case timeout, unsupported, cancelled, internalFailure = "internal_failure"
}

public enum AnalyticsPolishPreset: String, Codable, Sendable {
    case concise, professional, casual, custom
}

public enum AnalyticsSurface: String, Codable, Sendable {
    case onboarding, settings, history, insights, recording, keyboard, menuBar = "menu_bar"
}

public enum AnalyticsHistoryAction: String, Codable, Sendable {
    case search, copy, delete, export
    case clearAll = "clear_all"
}
public enum AnalyticsModelSizeBucket: String, Codable, Sendable {
    case under100MB = "<100mb"
    case megabytes100To500 = "100-500mb"
    case megabytes500ToOneGB = "500mb-1gb"
    case oneToFiveGB = "1-5gb"
    case overFiveGB = ">5gb"
}

public enum AnalyticsProviderConfigurationMethod: String, Codable, Sendable {
    case manual
    case iCloudSync = "icloud_sync"
}

public enum AnalyticsSettingID: String, Codable, Sendable {
    case transcriptionProvider = "transcription_provider"
    case transcriptionMode = "transcription_mode"
    case language, outputMethod = "output_method"
    case postProcessing = "post_processing"
    case historyRetention = "history_retention"
    case voiceOutput = "voice_output"
}

public enum AnalyticsSettingCategory: String, Codable, Sendable {
    case transcription, output, privacy, history, voice
}

public struct AnalyticsTranscriptionDimensions: Equatable, Sendable {
    public let mode: AnalyticsTranscriptionMode
    public let engine: AnalyticsEngineType
    public let provider: AnalyticsProviderType
    public let modelFamily: String
    public let languageCode: String
    public let trigger: AnalyticsTriggerSource

    public init(
        mode: AnalyticsTranscriptionMode,
        engine: AnalyticsEngineType,
        provider: AnalyticsProviderType,
        modelFamily: String,
        languageCode: String,
        trigger: AnalyticsTriggerSource
    ) {
        self.mode = mode
        self.engine = engine
        self.provider = provider
        self.modelFamily = Self.boundedIdentifier(modelFamily)
        self.languageCode = Self.boundedLanguageCode(languageCode)
        self.trigger = trigger
    }

    var properties: [String: String] {
        [
            "mode": mode.rawValue,
            "engine_type": engine.rawValue,
            "provider_type": provider.rawValue,
            "model_family": modelFamily,
            "language_code": languageCode,
            "trigger": trigger.rawValue
        ]
    }

    private static func boundedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard value.count <= 64, value.unicodeScalars.allSatisfy(allowed.contains) else { return "other" }
        return value.lowercased()
    }

    private static func boundedLanguageCode(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let allowed = CharacterSet.lowercaseLetters.union(CharacterSet(charactersIn: "-"))
        guard normalized.count <= 12, normalized.unicodeScalars.allSatisfy(allowed.contains) else { return "other" }
        return normalized
    }
}
