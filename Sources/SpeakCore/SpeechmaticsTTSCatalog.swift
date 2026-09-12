import Foundation

public enum SpeechmaticsTTSVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

public enum SpeechmaticsTTSVoiceAccent: String, Codable, Hashable, Sendable {
    case american
    case british

    public var displayName: String {
        switch self {
        case .american: "US"
        case .british: "UK"
        }
    }
}

/// One Speechmatics voice. The identifier is a URL path segment, not a request
/// field: synthesis posts to `/generate/<id>`.
public struct SpeechmaticsTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let gender: SpeechmaticsTTSVoiceGender
    public let accent: SpeechmaticsTTSVoiceAccent

    public init(
        id: String,
        name: String,
        gender: SpeechmaticsTTSVoiceGender,
        accent: SpeechmaticsTTSVoiceAccent
    ) {
        self.id = id
        self.name = name
        self.gender = gender
        self.accent = accent
    }

    public var apiVoiceID: String { id }

    public var providerVoiceID: String { "\(SpeechmaticsTTSCatalog.voiceIDPrefix)\(id)" }

    public var displayName: String {
        "\(name) (\(accent.displayName), \(gender.displayName))"
    }
}

/// Canonical Speechmatics text-to-speech catalogue.
///
/// Speechmatics documents four English voices and no model selector: the voice
/// is the whole choice. Speaking rate, pitch and language are not request
/// parameters, so the app's speed/pitch controls have nothing to send.
public enum SpeechmaticsTTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    public static let voiceIDPrefix = "speechmatics/"

    /// Every voice the text-to-speech quickstart lists. English only —
    /// Speechmatics has not published additional languages.
    public static let voices: [SpeechmaticsTTSVoice] = [
        SpeechmaticsTTSVoice(id: "sarah", name: "Sarah", gender: .female, accent: .british),
        SpeechmaticsTTSVoice(id: "theo", name: "Theo", gender: .male, accent: .british),
        SpeechmaticsTTSVoice(id: "megan", name: "Megan", gender: .female, accent: .american),
        SpeechmaticsTTSVoice(id: "jack", name: "Jack", gender: .male, accent: .american)
    ]

    public static var defaultVoice: SpeechmaticsTTSVoice {
        // The catalogue is a non-empty literal; the fallback keeps the accessor
        // total without a force unwrap.
        voices.first ?? SpeechmaticsTTSVoice(
            id: "sarah",
            name: "Sarah",
            gender: .female,
            accent: .british
        )
    }

    /// Strips the `speechmatics/` routing prefix, leaving the raw voice id.
    public static func apiVoiceID(forVoiceID voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(voiceIDPrefix) else { return trimmed }
        return String(trimmed.dropFirst(voiceIDPrefix.count))
    }

    public static func voice(forID voiceID: String) -> SpeechmaticsTTSVoice? {
        let identifier = apiVoiceID(forVoiceID: voiceID)
        return voices.first { $0.id == identifier }
    }

    /// Resolves the voice a request should use. Unlike providers with an open
    /// voice library, an unrecognised identifier here would become a 404 path,
    /// so it falls back to the default voice.
    public static func resolvedAPIVoiceID(forVoiceID voiceID: String) -> String {
        voice(forID: voiceID)?.apiVoiceID ?? defaultVoice.apiVoiceID
    }
}
