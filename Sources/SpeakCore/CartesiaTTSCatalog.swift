import Foundation

/// Cartesia Sonic speech-generation models exposed by the shared voice catalogue.
///
/// `sonic-3.6` is the generally-available flagship and the only model Speak
/// selects today. The older families stay listed because a stored selection may
/// still name one and because regional pronunciation (`locale`) is only
/// available from Sonic 3.6 onwards — the request builder needs to know which
/// model it is talking to before it can send a locale.
public enum CartesiaTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case sonic36 = "sonic-3.6"
    case sonic35 = "sonic-3.5"
    case sonic3 = "sonic-3"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sonic36: "Sonic 3.6"
        case .sonic35: "Sonic 3.5"
        case .sonic3: "Sonic 3"
        }
    }

    /// Whether the model accepts `locale` (for example `en-GB`). Older models
    /// take the base `language` code only, and Cartesia rejects a request that
    /// carries both fields.
    public var supportsLocale: Bool {
        switch self {
        case .sonic36: true
        case .sonic35, .sonic3: false
        }
    }
}

public enum CartesiaTTSVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

/// The accent a built-in Cartesia voice keeps regardless of the language it speaks.
public enum CartesiaTTSVoiceAccent: String, Codable, Hashable, Sendable {
    case american
    case british

    public var displayName: String { rawValue.capitalized }

    public var localeIdentifier: String {
        switch self {
        case .american: "en-US"
        case .british: "en-GB"
        }
    }
}

/// A Cartesia voice UUID plus the metadata the pickers display.
public struct CartesiaTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let gender: CartesiaTTSVoiceGender
    public let accent: CartesiaTTSVoiceAccent

    public init(
        id: String,
        name: String,
        gender: CartesiaTTSVoiceGender,
        accent: CartesiaTTSVoiceAccent
    ) {
        self.id = id
        self.name = name
        self.gender = gender
        self.accent = accent
    }

    /// The value Cartesia expects in the request `voice` field.
    public var apiVoiceID: String { id }

    public var providerVoiceID: String { "\(CartesiaTTSCatalog.voiceIDPrefix)\(id)" }

    public var displayName: String {
        "\(name) (\(accent.displayName), \(gender.displayName))"
    }
}

/// One voice as returned by `GET /voices`.
///
/// The account listing carries free-form metadata Cartesia can extend at any
/// time, so it is decoded into its own type rather than forced into the
/// built-in ``CartesiaTTSVoice`` shape.
public struct CartesiaRemoteVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let language: String?

    public init(id: String, name: String, description: String? = nil, language: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.language = language
    }

    public var providerVoiceID: String { "\(CartesiaTTSCatalog.voiceIDPrefix)\(id)" }
}

/// Canonical Cartesia Sonic catalogue and voice-identifier conventions.
public enum CartesiaTTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    public static let voiceIDPrefix = "cartesia/"

    public static let defaultModel: CartesiaTTSModel = .sonic36
    public static let models = CartesiaTTSModel.allCases

    /// The voices Cartesia documents for Sonic 3.6. They are the offline
    /// fallback: `GET /voices` returns the full library (plus any cloned voices)
    /// once a key is stored, but the picker must still show something useful
    /// before a key exists or when the network is unavailable.
    public static let voices: [CartesiaTTSVoice] = [
        CartesiaTTSVoice(
            id: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
            name: "Skylar",
            gender: .female,
            accent: .american
        ),
        CartesiaTTSVoice(
            id: "47c38ca4-5f35-497b-b1a3-415245fb35e1",
            name: "Daniel",
            gender: .male,
            accent: .american
        ),
        CartesiaTTSVoice(
            id: "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc",
            name: "Jacqueline",
            gender: .female,
            accent: .american
        ),
        CartesiaTTSVoice(
            id: "62ae83ad-4f6a-430b-af41-a9bede9286ca",
            name: "Gemma",
            gender: .female,
            accent: .british
        ),
        CartesiaTTSVoice(
            id: "ef191366-f52f-447a-a398-ed8c0f2943a1",
            name: "Archie",
            gender: .male,
            accent: .british
        )
    ]

    public static var defaultVoice: CartesiaTTSVoice {
        // The catalogue is a non-empty literal; the fallback keeps the accessor
        // total without a force unwrap.
        voices.first ?? CartesiaTTSVoice(
            id: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
            name: "Skylar",
            gender: .female,
            accent: .american
        )
    }

    /// Strips the `cartesia/` routing prefix, leaving the raw Cartesia voice UUID.
    public static func apiVoiceID(forVoiceID voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(voiceIDPrefix) else { return trimmed }
        return String(trimmed.dropFirst(voiceIDPrefix.count))
    }

    /// Looks a built-in voice up by either its prefixed or raw identifier.
    public static func voice(forID voiceID: String) -> CartesiaTTSVoice? {
        let identifier = apiVoiceID(forVoiceID: voiceID)
        return voices.first { $0.id == identifier }
    }

    /// Resolves the voice a request should use, falling back to the default when
    /// the stored identifier names a voice that is not in the built-in list.
    ///
    /// An unknown identifier is still sent as-is: it is most likely a library or
    /// cloned voice that only `GET /voices` knows about.
    public static func resolvedAPIVoiceID(forVoiceID voiceID: String) -> String {
        let identifier = apiVoiceID(forVoiceID: voiceID)
        return identifier.isEmpty ? defaultVoice.apiVoiceID : identifier
    }
}
