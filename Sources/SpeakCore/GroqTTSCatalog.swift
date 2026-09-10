import Foundation

/// Groq-hosted Orpheus speech-generation models.
///
/// Groq retired `playai-tts` and `playai-tts-arabic` on 31 December 2025 and
/// replaced them with these Canopy Labs models. The retired identifiers are
/// deliberately absent: a request naming one now fails, so it must never be
/// selectable.
public enum GroqTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case orpheusEnglish = "canopylabs/orpheus-v1-english"
    case orpheusArabicSaudi = "canopylabs/orpheus-arabic-saudi"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orpheusEnglish: "Orpheus v1 English"
        case .orpheusArabicSaudi: "Orpheus Arabic (Saudi)"
        }
    }

    /// The segment used inside a stored voice identifier, so the full model
    /// namespace does not have to survive a round trip through settings.
    public var slug: String {
        switch self {
        case .orpheusEnglish: "orpheus-v1-english"
        case .orpheusArabicSaudi: "orpheus-arabic-saudi"
        }
    }

    public var languageCode: String {
        switch self {
        case .orpheusEnglish: "en"
        case .orpheusArabicSaudi: "ar"
        }
    }

    /// Published rate per million characters, expressed per thousand for the
    /// app's estimate.
    public var costPerThousandCharacters: Decimal {
        switch self {
        case .orpheusEnglish: Decimal(string: "0.022") ?? 0
        case .orpheusArabicSaudi: Decimal(string: "0.040") ?? 0
        }
    }

    /// Bracketed vocal directions such as `[cheerful]` are documented for the
    /// English model only.
    public var supportsVocalDirections: Bool {
        switch self {
        case .orpheusEnglish: true
        case .orpheusArabicSaudi: false
        }
    }
}

public enum GroqTTSVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

/// One Orpheus voice persona plus the model it belongs to.
public struct GroqTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let gender: GroqTTSVoiceGender
    public let model: GroqTTSModel

    public init(id: String, name: String, gender: GroqTTSVoiceGender, model: GroqTTSModel) {
        self.id = id
        self.name = name
        self.gender = gender
        self.model = model
    }

    /// The value Groq expects in the request `voice` field.
    public var apiVoiceID: String { id }

    /// Stored identifier. The model travels with the voice because the two
    /// personas lists do not overlap and a voice is only valid for its model.
    public var providerVoiceID: String {
        "\(GroqTTSCatalog.voiceIDPrefix)\(model.slug)/\(id)"
    }

    public var displayName: String {
        "\(name) · \(model.displayName)"
    }
}

/// Canonical Groq Orpheus catalogue and voice-identifier conventions.
public enum GroqTTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    public static let voiceIDPrefix = "groq/"

    public static let defaultModel: GroqTTSModel = .orpheusEnglish
    public static let models = GroqTTSModel.allCases

    /// The twelve personas Groq documents — six per model. Groq hosts its own
    /// persona set; the upstream open-source Orpheus voice names are not valid
    /// here.
    public static let voices: [GroqTTSVoice] = [
        GroqTTSVoice(id: "autumn", name: "Autumn", gender: .female, model: .orpheusEnglish),
        GroqTTSVoice(id: "diana", name: "Diana", gender: .female, model: .orpheusEnglish),
        GroqTTSVoice(id: "hannah", name: "Hannah", gender: .female, model: .orpheusEnglish),
        GroqTTSVoice(id: "austin", name: "Austin", gender: .male, model: .orpheusEnglish),
        GroqTTSVoice(id: "daniel", name: "Daniel", gender: .male, model: .orpheusEnglish),
        GroqTTSVoice(id: "troy", name: "Troy", gender: .male, model: .orpheusEnglish),
        GroqTTSVoice(id: "lulwa", name: "Lulwa", gender: .female, model: .orpheusArabicSaudi),
        GroqTTSVoice(id: "noura", name: "Noura", gender: .female, model: .orpheusArabicSaudi),
        GroqTTSVoice(id: "aisha", name: "Aisha", gender: .female, model: .orpheusArabicSaudi),
        GroqTTSVoice(id: "abdullah", name: "Abdullah", gender: .male, model: .orpheusArabicSaudi),
        GroqTTSVoice(id: "fahad", name: "Fahad", gender: .male, model: .orpheusArabicSaudi),
        GroqTTSVoice(id: "sultan", name: "Sultan", gender: .male, model: .orpheusArabicSaudi)
    ]

    public static var defaultVoice: GroqTTSVoice {
        // The catalogue is a non-empty literal; the fallback keeps the accessor
        // total without a force unwrap.
        voices.first ?? GroqTTSVoice(
            id: "autumn",
            name: "Autumn",
            gender: .female,
            model: .orpheusEnglish
        )
    }

    /// Looks a voice up by its stored (`groq/orpheus-v1-english/austin`) or raw
    /// (`austin`) identifier.
    public static func voice(forID voiceID: String) -> GroqTTSVoice? {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix(voiceIDPrefix)
            ? String(trimmed.dropFirst(voiceIDPrefix.count))
            : trimmed
        let parts = stripped.split(separator: "/", maxSplits: 1).map(String.init)
        guard let last = parts.last else { return nil }
        if parts.count == 2, let model = models.first(where: { $0.slug == parts[0] }) {
            return voices.first { $0.id == last && $0.model == model }
        }
        return voices.first { $0.id == last }
    }

    /// Resolves the voice a request should use. A voice Groq does not host
    /// would be rejected, so an unknown identifier falls back to the default.
    public static func resolvedVoice(forID voiceID: String) -> GroqTTSVoice {
        voice(forID: voiceID) ?? defaultVoice
    }
}
