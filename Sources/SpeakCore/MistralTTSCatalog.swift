import Foundation

/// Mistral Voxtral speech-generation models.
public enum MistralTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// Dated release. Speak pins this so a model revision cannot silently
    /// change what a saved voice sounds like.
    case voxtralMiniTTS2603 = "voxtral-mini-tts-2603"
    /// Rolling alias Mistral keeps pointed at the newest Voxtral TTS release.
    case voxtralMiniTTSLatest = "voxtral-mini-tts-latest"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .voxtralMiniTTS2603: "Voxtral TTS 26.03"
        case .voxtralMiniTTSLatest: "Voxtral TTS (latest)"
        }
    }
}

/// One voice as returned by `GET /v1/audio/voices`.
///
/// Mistral publishes no preset voice list in its documentation: presets and
/// cloned voices share one UUID space and are only discoverable at runtime. The
/// picker therefore has nothing to show until a key is stored, which is also
/// the only point at which a Voxtral voice could actually be spoken.
public struct MistralTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let slug: String?
    public let gender: String?
    public let languages: [String]?
    public let description: String?

    public init(
        id: String,
        name: String,
        slug: String? = nil,
        gender: String? = nil,
        languages: [String]? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.gender = gender
        self.languages = languages
        self.description = description
    }

    /// The value Mistral expects in the request `voice_id` field.
    public var apiVoiceID: String { id }

    public var providerVoiceID: String { "\(MistralTTSCatalog.voiceIDPrefix)\(id)" }

    public var displayName: String {
        guard let gender, !gender.isEmpty else { return name }
        return "\(name) (\(gender.capitalized))"
    }
}

/// Canonical Mistral Voxtral catalogue and voice-identifier conventions.
public enum MistralTTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    public static let voiceIDPrefix = "mistral/"

    public static let defaultModel: MistralTTSModel = .voxtralMiniTTS2603
    public static let models = MistralTTSModel.allCases

    /// Languages the Voxtral TTS guide lists.
    public static let supportedLanguageCodes = [
        "en", "fr", "es", "pt", "it", "nl", "de", "hi", "ar"
    ]

    /// Strips the `mistral/` routing prefix, leaving the raw voice UUID.
    public static func apiVoiceID(forVoiceID voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(voiceIDPrefix) else { return trimmed }
        return String(trimmed.dropFirst(voiceIDPrefix.count))
    }
}
