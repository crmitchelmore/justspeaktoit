import Foundation

/// Gemini speech-generation models reachable over the Interactions API.
///
/// Google lists three TTS models on that surface. This catalogue carries the
/// newest, which supersedes the two `gemini-2.5-*-preview-tts` entries and is
/// the only one of the three that supports streaming; the older previews work
/// but add a choice with no benefit attached, so they are left out until
/// something asks for them.
public enum GeminiTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case flash31TTSPreview = "gemini-3.1-flash-tts-preview"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flash31TTSPreview: "Gemini 3.1 Flash TTS"
        }
    }

    /// Output audio is billed per token at 25 tokens per second of speech.
    /// `gemini-3.1-flash-tts-preview` bills audio output at $20 per million
    /// tokens, so a second of speech costs 25 × $20 ÷ 1,000,000.
    public var costPerSecondOfSpeech: Decimal {
        switch self {
        case .flash31TTSPreview: Decimal(string: "0.0005") ?? 0
        }
    }

    /// The submitted text is billed too, at $1 per million input tokens —
    /// small beside the audio charge, but not zero, so it belongs in the
    /// recorded cost rather than being dropped.
    public var costPerInputToken: Decimal {
        switch self {
        case .flash31TTSPreview: Decimal(string: "0.000001") ?? 0
        }
    }

    /// Characters per input token when a response carries no usage block.
    ///
    /// Four characters per token is Google's own published rule of thumb for
    /// Gemini text. It is an estimate, and the cost it feeds is documented as
    /// one.
    public static let estimatedCharactersPerInputToken = 4

    /// The input charge for `characterCount` when the response reported
    /// `reportedTokens`, falling back to the documented estimate when it did
    /// not.
    public func inputCost(characterCount: Int, reportedTokens: Int?) -> Decimal {
        let tokens = reportedTokens ?? Int(
            (Double(characterCount) / Double(Self.estimatedCharactersPerInputToken)).rounded(.up)
        )
        guard tokens > 0 else { return 0 }
        return Decimal(tokens) * costPerInputToken
    }
}

/// One prebuilt Gemini voice and the one-word character Google gives it.
public struct GeminiTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let character: String

    public init(id: String, character: String) {
        self.id = id
        self.character = character
    }

    /// The value Gemini expects in `generation_config.speech_config[].voice`.
    public var apiVoiceName: String { id }

    public var providerVoiceID: String { "\(GeminiTTSCatalog.voiceIDPrefix)\(id)" }

    public var displayName: String { "\(id) · \(character)" }
}

/// Canonical Gemini speech-generation catalogue.
public enum GeminiTTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    ///
    /// It matches the `google` provider naming used by Gemini transcription, so
    /// one Google credential covers both directions.
    public static let voiceIDPrefix = "google/"

    public static let defaultModel: GeminiTTSModel = .flash31TTSPreview
    public static let models = GeminiTTSModel.allCases

    /// The thirty prebuilt voices the speech-generation guide documents.
    public static let voices: [GeminiTTSVoice] = [
        GeminiTTSVoice(id: "Zephyr", character: "Bright"),
        GeminiTTSVoice(id: "Puck", character: "Upbeat"),
        GeminiTTSVoice(id: "Charon", character: "Informative"),
        GeminiTTSVoice(id: "Kore", character: "Firm"),
        GeminiTTSVoice(id: "Fenrir", character: "Excitable"),
        GeminiTTSVoice(id: "Leda", character: "Youthful"),
        GeminiTTSVoice(id: "Orus", character: "Firm"),
        GeminiTTSVoice(id: "Aoede", character: "Breezy"),
        GeminiTTSVoice(id: "Callirrhoe", character: "Easy-going"),
        GeminiTTSVoice(id: "Autonoe", character: "Bright"),
        GeminiTTSVoice(id: "Enceladus", character: "Breathy"),
        GeminiTTSVoice(id: "Iapetus", character: "Clear"),
        GeminiTTSVoice(id: "Umbriel", character: "Easy-going"),
        GeminiTTSVoice(id: "Algieba", character: "Smooth"),
        GeminiTTSVoice(id: "Despina", character: "Smooth"),
        GeminiTTSVoice(id: "Erinome", character: "Clear"),
        GeminiTTSVoice(id: "Algenib", character: "Gravelly"),
        GeminiTTSVoice(id: "Rasalgethi", character: "Informative"),
        GeminiTTSVoice(id: "Laomedeia", character: "Upbeat"),
        GeminiTTSVoice(id: "Achernar", character: "Soft"),
        GeminiTTSVoice(id: "Alnilam", character: "Firm"),
        GeminiTTSVoice(id: "Schedar", character: "Even"),
        GeminiTTSVoice(id: "Gacrux", character: "Mature"),
        GeminiTTSVoice(id: "Pulcherrima", character: "Forward"),
        GeminiTTSVoice(id: "Achird", character: "Friendly"),
        GeminiTTSVoice(id: "Zubenelgenubi", character: "Casual"),
        GeminiTTSVoice(id: "Vindemiatrix", character: "Gentle"),
        GeminiTTSVoice(id: "Sadachbia", character: "Lively"),
        GeminiTTSVoice(id: "Sadaltager", character: "Knowledgeable"),
        GeminiTTSVoice(id: "Sulafat", character: "Warm")
    ]

    public static var defaultVoice: GeminiTTSVoice {
        // The catalogue is a non-empty literal; the fallback keeps the accessor
        // total without a force unwrap.
        voices.first ?? GeminiTTSVoice(id: "Zephyr", character: "Bright")
    }

    /// Strips the `google/` routing prefix, leaving the raw voice name.
    public static func apiVoiceName(forVoiceID voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(voiceIDPrefix) else { return trimmed }
        return String(trimmed.dropFirst(voiceIDPrefix.count))
    }

    /// Looks a voice up by either its prefixed or raw identifier. Gemini
    /// accepts the name case-insensitively, so a stored lower-cased value still
    /// resolves.
    public static func voice(forID voiceID: String) -> GeminiTTSVoice? {
        let name = apiVoiceName(forVoiceID: voiceID)
        return voices.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Resolves the voice a request should use. Gemini rejects an unknown voice
    /// name, so an unrecognised identifier falls back to the default.
    public static func resolvedVoice(forID voiceID: String) -> GeminiTTSVoice {
        voice(forID: voiceID) ?? defaultVoice
    }
}
