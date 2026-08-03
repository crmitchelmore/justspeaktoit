import Foundation

/// Deepgram Aura model families exposed by the shared voice catalogue.
public enum DeepgramTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case aura2 = "aura-2"
    case aura1 = "aura"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aura2: "Aura 2 (English)"
        case .aura1: "Aura 1 (English)"
        }
    }
}

public enum DeepgramTTSVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

public enum DeepgramTTSVoiceAccent: String, Codable, Hashable, Sendable {
    case american
    case australian
    case british
    case filipino
    case irish

    public var displayName: String { rawValue.capitalized }

    public var localeIdentifier: String {
        switch self {
        case .american: "en-US"
        case .australian: "en-AU"
        case .british: "en-GB"
        case .filipino: "en-PH"
        case .irish: "en-IE"
        }
    }
}

public enum DeepgramTTSVoiceStyle: String, Codable, Hashable, Sendable {
    case casual
    case clear
    case deep
    case energetic
    case professional
    case warm
}

/// A complete Deepgram API voice identifier and its picker metadata.
public struct DeepgramTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let model: DeepgramTTSModel
    public let gender: DeepgramTTSVoiceGender
    public let accent: DeepgramTTSVoiceAccent
    public let style: DeepgramTTSVoiceStyle

    public var providerVoiceID: String { "deepgram/\(id)" }

    public var displayName: String {
        "\(name) (\(accent.displayName), \(gender.displayName))"
    }
}

public struct DeepgramTTSSelection: Equatable, Sendable {
    public let model: DeepgramTTSModel
    public let voice: DeepgramTTSVoice
}

/// Canonical Deepgram Aura catalogue, defaults, compatibility, and legacy migrations.
public enum DeepgramTTSCatalog {
    public static let defaultModel: DeepgramTTSModel = .aura2
    public static let models = DeepgramTTSModel.allCases
    public static let voices = aura2EnglishVoices + aura1EnglishVoices

    public static func model(forLegacyID id: String?) -> DeepgramTTSModel? {
        switch id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "aura-2", "aura2", "aura_2": .aura2
        case "aura", "aura-1", "aura1", "aura_1": .aura1
        default: nil
        }
    }

    public static func voices(for model: DeepgramTTSModel) -> [DeepgramTTSVoice] {
        voices.filter { $0.model == model }
    }

    public static func voices(forModelID modelID: String) -> [DeepgramTTSVoice] {
        voices(for: model(forLegacyID: modelID) ?? defaultModel)
    }

    public static func voice(forID id: String) -> DeepgramTTSVoice? {
        let normalized = normalizedVoiceID(id)
        return voices.first { $0.id == normalized }
    }

    public static func defaultVoice(for model: DeepgramTTSModel) -> DeepgramTTSVoice {
        let defaultID = model == .aura2 ? "aura-2-asteria-en" : "aura-asteria-en"
        guard let fallback = voices(for: model).first else {
            preconditionFailure("Deepgram catalogue model must contain at least one voice")
        }
        return voices.first { $0.id == defaultID } ?? fallback
    }

    /// Normalizes old model prefixes, short voice names, provider-prefixed IDs, and invalid pairs.
    public static func resolvedSelection(
        modelID: String?,
        voiceID: String?
    ) -> DeepgramTTSSelection {
        let normalizedVoiceID = voiceID.map(normalizedVoiceID)
        let exactVoice = normalizedVoiceID.flatMap { normalizedID in
            voices.first { $0.id == normalizedID }
        }
        let model = model(forLegacyID: modelID) ?? exactVoice?.model ?? defaultModel

        if let exactVoice, exactVoice.model == model {
            return DeepgramTTSSelection(model: model, voice: exactVoice)
        }

        let legacyName = exactVoice?.name.lowercased()
            ?? normalizedVoiceID?.lowercased()
        if let legacyName,
           let compatibleVoice = voices(for: model).first(where: {
               $0.name.lowercased() == legacyName
           }) {
            return DeepgramTTSSelection(model: model, voice: compatibleVoice)
        }

        return DeepgramTTSSelection(model: model, voice: defaultVoice(for: model))
    }

    private static func normalizedVoiceID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "deepgram/", with: "")
    }

    // English voice metadata verified against Deepgram's Aura voice catalogue.
    private static let aura2EnglishVoices: [DeepgramTTSVoice] = [
        voice("aura-2-amalthea-en", "Amalthea", .aura2, .female, .filipino, .energetic),
        voice("aura-2-andromeda-en", "Andromeda", .aura2, .female, .american, .casual),
        voice("aura-2-apollo-en", "Apollo", .aura2, .male, .american, .casual),
        voice("aura-2-arcas-en", "Arcas", .aura2, .male, .american, .clear),
        voice("aura-2-aries-en", "Aries", .aura2, .male, .american, .warm),
        voice("aura-2-asteria-en", "Asteria", .aura2, .female, .american, .clear),
        voice("aura-2-athena-en", "Athena", .aura2, .female, .american, .professional),
        voice("aura-2-atlas-en", "Atlas", .aura2, .male, .american, .energetic),
        voice("aura-2-aurora-en", "Aurora", .aura2, .female, .american, .energetic),
        voice("aura-2-callista-en", "Callista", .aura2, .female, .american, .professional),
        voice("aura-2-cora-en", "Cora", .aura2, .female, .american, .warm),
        voice("aura-2-cordelia-en", "Cordelia", .aura2, .female, .american, .warm),
        voice("aura-2-delia-en", "Delia", .aura2, .female, .american, .casual),
        voice("aura-2-draco-en", "Draco", .aura2, .male, .british, .deep),
        voice("aura-2-electra-en", "Electra", .aura2, .female, .american, .professional),
        voice("aura-2-harmonia-en", "Harmonia", .aura2, .female, .american, .clear),
        voice("aura-2-helena-en", "Helena", .aura2, .female, .american, .warm),
        voice("aura-2-hera-en", "Hera", .aura2, .female, .american, .professional),
        voice("aura-2-hermes-en", "Hermes", .aura2, .male, .american, .professional),
        voice("aura-2-hyperion-en", "Hyperion", .aura2, .male, .australian, .warm),
        voice("aura-2-iris-en", "Iris", .aura2, .female, .american, .energetic),
        voice("aura-2-janus-en", "Janus", .aura2, .female, .american, .professional),
        voice("aura-2-juno-en", "Juno", .aura2, .female, .american, .casual),
        voice("aura-2-jupiter-en", "Jupiter", .aura2, .male, .american, .deep),
        voice("aura-2-luna-en", "Luna", .aura2, .female, .american, .warm),
        voice("aura-2-mars-en", "Mars", .aura2, .male, .american, .deep),
        voice("aura-2-minerva-en", "Minerva", .aura2, .female, .american, .warm),
        voice("aura-2-neptune-en", "Neptune", .aura2, .male, .american, .professional),
        voice("aura-2-odysseus-en", "Odysseus", .aura2, .male, .american, .professional),
        voice("aura-2-ophelia-en", "Ophelia", .aura2, .female, .american, .energetic),
        voice("aura-2-orion-en", "Orion", .aura2, .male, .american, .casual),
        voice("aura-2-orpheus-en", "Orpheus", .aura2, .male, .american, .professional),
        voice("aura-2-pandora-en", "Pandora", .aura2, .female, .british, .warm),
        voice("aura-2-phoebe-en", "Phoebe", .aura2, .female, .american, .energetic),
        voice("aura-2-pluto-en", "Pluto", .aura2, .male, .american, .deep),
        voice("aura-2-saturn-en", "Saturn", .aura2, .male, .american, .deep),
        voice("aura-2-selene-en", "Selene", .aura2, .female, .american, .energetic),
        voice("aura-2-thalia-en", "Thalia", .aura2, .female, .american, .clear),
        voice("aura-2-theia-en", "Theia", .aura2, .female, .australian, .professional),
        voice("aura-2-vesta-en", "Vesta", .aura2, .female, .american, .warm),
        voice("aura-2-zeus-en", "Zeus", .aura2, .male, .american, .deep)
    ]

    private static let aura1EnglishVoices: [DeepgramTTSVoice] = [
        voice("aura-asteria-en", "Asteria", .aura1, .female, .american, .clear),
        voice("aura-luna-en", "Luna", .aura1, .female, .american, .warm),
        voice("aura-stella-en", "Stella", .aura1, .female, .american, .professional),
        voice("aura-athena-en", "Athena", .aura1, .female, .british, .professional),
        voice("aura-hera-en", "Hera", .aura1, .female, .american, .professional),
        voice("aura-orion-en", "Orion", .aura1, .male, .american, .casual),
        voice("aura-arcas-en", "Arcas", .aura1, .male, .american, .clear),
        voice("aura-perseus-en", "Perseus", .aura1, .male, .american, .professional),
        voice("aura-angus-en", "Angus", .aura1, .male, .irish, .warm),
        voice("aura-orpheus-en", "Orpheus", .aura1, .male, .american, .professional),
        voice("aura-helios-en", "Helios", .aura1, .male, .british, .professional),
        voice("aura-zeus-en", "Zeus", .aura1, .male, .american, .deep)
    ]

    // The catalogue reads like a compact table; keeping all six fields here makes drift obvious.
    // swiftlint:disable:next function_parameter_count
    private static func voice(
        _ id: String,
        _ name: String,
        _ model: DeepgramTTSModel,
        _ gender: DeepgramTTSVoiceGender,
        _ accent: DeepgramTTSVoiceAccent,
        _ style: DeepgramTTSVoiceStyle
    ) -> DeepgramTTSVoice {
        DeepgramTTSVoice(
            id: id,
            name: name,
            model: model,
            gender: gender,
            accent: accent,
            style: style
        )
    }
}
