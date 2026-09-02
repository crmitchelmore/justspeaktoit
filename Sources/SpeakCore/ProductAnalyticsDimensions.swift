import Foundation

public enum AnalyticsPermissionType: String, Codable, Sendable {
    case microphone, speech, accessibility, notifications
    case localNetwork = "local_network"
}

public enum AnalyticsPermissionState: String, Codable, Sendable { case granted, denied, restricted }
public enum AnalyticsTranscriptionMode: String, Codable, Sendable { case live, batch }
public enum AnalyticsTriggerSource: String, Codable, Sendable {
    case hotkey, keyboard, watch, widget
    case menuBar = "menu_bar"
    case actionButton = "action_button"
    case handsFree = "hands_free"
    case urlScheme = "url_scheme"
    case voiceEdit = "voice_edit"
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

/// The closed set of transcription model families this app ships, plus an `other` escape hatch.
///
/// This is deliberately an enum rather than a sanitised `String`: a string-typed model family is a
/// hole through which arbitrary user content could reach the wire, and no character-set filter can
/// close it (`CharacterSet.alphanumerics` is Unicode-wide, so an entire CJK sentence passes it).
/// Call sites must map their concrete model identifier onto a case here or report `.other`.
public enum AnalyticsModelFamily: String, Codable, Sendable {
    /// Apple's on-device `SpeechTranscriber` / Dictation.
    case apple
    /// OpenAI `whisper-1`, Groq Whisper, and every local WhisperKit variant.
    case whisper
    /// NVIDIA Parakeet TDT, both the sherpa-onnx and FluidAudio realtime builds.
    case parakeet
    /// NVIDIA Nemotron streaming speech, run locally through sherpa-onnx.
    case nemotron
    /// sherpa-onnx streaming Zipformer.
    case zipformer
    /// Deepgram Nova / Enhanced / Base.
    case nova
    /// Deepgram Flux streaming.
    case flux
    /// AssemblyAI Universal.
    case universal
    /// ElevenLabs Scribe.
    case scribe
    /// OpenAI GPT-4o / GPT-realtime transcription models.
    case gptTranscribe = "gpt_transcribe"
    /// Mistral Voxtral.
    case voxtral
    /// Soniox real-time and async speech-to-text.
    case soniox
    /// Modulate Velma.
    case velma
    /// Cartesia Ink.
    case ink
    /// Gladia Solaria.
    case solaria
    /// Speechmatics streaming and batch.
    case speechmatics
    /// Google Gemini audio models used as transcribers.
    case gemini
    /// xAI Grok Voice models used in transcription-only mode.
    case grok
    /// Meta Muse Voice Transcribe.
    case muse
    /// Rev.ai.
    case revAI = "rev_ai"
    /// Anything not in the list above — never the caller's own identifier.
    case other
}

public struct AnalyticsTranscriptionDimensions: Equatable, Sendable {
    public let mode: AnalyticsTranscriptionMode
    public let engine: AnalyticsEngineType
    public let provider: AnalyticsProviderType
    public let modelFamily: AnalyticsModelFamily
    public let languageCode: String
    public let trigger: AnalyticsTriggerSource

    public init(
        mode: AnalyticsTranscriptionMode,
        engine: AnalyticsEngineType,
        provider: AnalyticsProviderType,
        modelFamily: AnalyticsModelFamily,
        languageCode: String,
        trigger: AnalyticsTriggerSource
    ) {
        self.mode = mode
        self.engine = engine
        self.provider = provider
        self.modelFamily = modelFamily
        self.languageCode = Self.boundedLanguageCode(languageCode)
        self.trigger = trigger
    }

    var properties: [String: String] {
        [
            "mode": mode.rawValue,
            "engine_type": engine.rawValue,
            "provider_type": provider.rawValue,
            "model_family": modelFamily.rawValue,
            "language_code": languageCode,
            "trigger": trigger.rawValue
        ]
    }

    /// Only identifiers represented by the shared transcription-language catalogue are emitted.
    /// Callers may supply the catalogue's underscore or BCP-47 hyphen spelling; everything else is
    /// collapsed to `other` so short ASCII user content cannot pass through this boundary.
    private static func boundedLanguageCode(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let identifiers = Set(TranscriptionLanguageCatalog.options.map {
            $0.id.lowercased().replacingOccurrences(of: "_", with: "-")
        })
        let baseLanguages = Set(identifiers.compactMap {
            $0.split(separator: "-", maxSplits: 1).first.map(String.init)
        })
        return identifiers.contains(normalized) || baseLanguages.contains(normalized) ? normalized : "other"
    }
}
