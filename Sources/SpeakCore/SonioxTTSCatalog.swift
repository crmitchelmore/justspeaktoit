import Foundation

/// Soniox real-time speech-generation models exposed by the shared voice catalogue.
///
/// Only the current model is offered. `tts-rt-v1` (and its `tts-rt-v1-preview`
/// alias) are wire-compatible with `tts-rt-v2` and retired by Soniox on
/// 31 August 2026, so stored selections are migrated forward rather than kept
/// selectable.
public enum SonioxTTSModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case realtimeV2 = "tts-rt-v2"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtimeV2: "Soniox TTS v2"
        }
    }
}

public enum SonioxTTSVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

/// The accent a Soniox voice keeps regardless of the language it speaks.
public enum SonioxTTSVoiceAccent: String, Codable, Hashable, Sendable {
    case american
    case australian
    case british
    case indian
    case spanish

    public var displayName: String { rawValue.capitalized }
}

public enum SonioxTTSVoiceStyle: String, Codable, Hashable, Sendable {
    case casual
    case clear
    case deep
    case energetic
    case professional
    case warm
}

/// A Soniox built-in voice name plus the metadata the pickers display.
public struct SonioxTTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let gender: SonioxTTSVoiceGender
    public let accent: SonioxTTSVoiceAccent
    public let style: SonioxTTSVoiceStyle

    /// The value Soniox expects in the request `voice` field.
    public var apiVoiceName: String { id }

    public var providerVoiceID: String { "soniox/\(id)" }

    public var displayName: String {
        "\(id) (\(accent.displayName), \(gender.displayName))"
    }
}

public struct SonioxTTSSelection: Equatable, Sendable {
    public let model: SonioxTTSModel
    public let voice: SonioxTTSVoice
}

/// Soniox processing region. A regional project key must only be sent to its matching hosts.
public enum SonioxTTSRegion: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case unitedStates = "us"
    case europe = "eu"
    case japan = "jp"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unitedStates: "United States"
        case .europe: "European Union"
        case .japan: "Japan"
        }
    }

    public var apiHost: String {
        switch self {
        case .unitedStates: "api.soniox.com"
        case .europe: "api.eu.soniox.com"
        case .japan: "api.jp.soniox.com"
        }
    }

    public var ttsHost: String {
        switch self {
        case .unitedStates: "tts-rt.soniox.com"
        case .europe: "tts-rt.eu.soniox.com"
        case .japan: "tts-rt.jp.soniox.com"
        }
    }

    public var modelsEndpoint: URL { URL(string: "https://\(apiHost)/v1/tts-models")! }
    public var voicesEndpoint: URL { URL(string: "https://\(apiHost)/v1/voices")! }
    public var speakEndpoint: URL { URL(string: "https://\(ttsHost)/tts")! }
    public var webSocketEndpoint: URL { URL(string: "wss://\(ttsHost)/tts-websocket")! }

    public static func migrated(from identifier: String?) -> SonioxTTSRegion {
        switch identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "eu", "europe", "european-union": .europe
        case "jp", "japan": .japan
        case "us", "usa", "united-states", "global", nil, "": .unitedStates
        default: .unitedStates
        }
    }
}

public enum SonioxTTSAccountVoiceStatus: String, Codable, Hashable, Sendable {
    case ready
    case notComputed = "not_computed"
    case failed
    case unknown
}

public struct SonioxTTSAccountVoiceModel: Codable, Hashable, Sendable {
    public let model: String
    public let status: String
    public let errorType: String?
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case model, status
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

/// A project-owned cloned voice returned by `GET /v1/voices`.
public struct SonioxTTSAccountVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let filename: String?
    public let models: [SonioxTTSAccountVoiceModel]

    public var providerVoiceID: String { "soniox/\(id)" }

    public func status(for model: SonioxTTSModel) -> SonioxTTSAccountVoiceStatus {
        guard let rawStatus = models.first(where: { $0.model == model.rawValue })?.status.lowercased() else {
            return .notComputed
        }
        return SonioxTTSAccountVoiceStatus(rawValue: rawStatus) ?? .unknown
    }
}

public enum SonioxTTSVoiceFallbackReason: Equatable, Sendable {
    case missingOrDeletedClone(lastKnownName: String?)
    case cloneNotReady(lastKnownName: String?)
}

public struct SonioxTTSResolvedVoice: Equatable, Sendable {
    public let apiVoiceID: String
    public let providerVoiceID: String
    public let displayName: String
    public let accountVoice: SonioxTTSAccountVoice?
    public let fallbackReason: SonioxTTSVoiceFallbackReason?
}

/// Canonical Soniox speech-generation catalogue, defaults and legacy migrations.
///
/// Soniox voices are language-independent: every voice speaks all supported
/// languages while keeping its own accent, so the catalogue is a flat list
/// rather than per-language sets.
public enum SonioxTTSCatalog {
    public static let defaultModel: SonioxTTSModel = .realtimeV2
    public static let models = SonioxTTSModel.allCases
    public static let voices = builtInVoices
    public static let defaultVoiceID = "Maya"
    /// Used only when neither content nor device locale yields a usable language.
    public static let defaultLanguageCode = "en"

    /// Compatibility entry point. Automatic now follows the device locale rather than transcription.
    public static func languageCode(forLocaleIdentifier identifier: String?) -> String {
        VoiceOutputLanguageCatalog.languageCode(for: identifier, content: "")
    }

    public static func languageCode(
        forVoiceOutputIdentifier identifier: String?,
        content: String,
        deviceLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        VoiceOutputLanguageCatalog.languageCode(
            for: identifier,
            content: content,
            deviceLocaleIdentifier: deviceLocaleIdentifier
        )
    }

    public static func requiredLanguageCode(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init)
        guard let normalized, !normalized.isEmpty else { return defaultLanguageCode }
        return normalized
    }

    /// Maps stored or superseded model identifiers onto a current model.
    public static func model(forLegacyID id: String?) -> SonioxTTSModel? {
        switch id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tts-rt-v2", "v2": .realtimeV2
        // v1 and its preview alias are wire-compatible; roll them forward.
        case "tts-rt-v1", "tts-rt-v1-preview", "v1": .realtimeV2
        default: nil
        }
    }

    public static func voices(for model: SonioxTTSModel) -> [SonioxTTSVoice] {
        switch model {
        case .realtimeV2: voices
        }
    }

    public static func voice(forID id: String) -> SonioxTTSVoice? {
        let normalized = normalizedVoiceID(id)
        return voices.first { $0.id.lowercased() == normalized }
    }

    public static func defaultVoice(for model: SonioxTTSModel) -> SonioxTTSVoice {
        guard let fallback = voices(for: model).first else {
            preconditionFailure("Soniox catalogue model must contain at least one voice")
        }
        return voices(for: model).first { $0.id == defaultVoiceID } ?? fallback
    }

    /// Normalizes provider-prefixed IDs, casing and retired model names, falling
    /// back to catalogue defaults when nothing matches.
    public static func resolvedSelection(
        modelID: String?,
        voiceID: String?
    ) -> SonioxTTSSelection {
        let resolvedModel = model(forLegacyID: modelID) ?? defaultModel
        guard let voiceID, let voice = voice(forID: voiceID) else {
            return SonioxTTSSelection(model: resolvedModel, voice: defaultVoice(for: resolvedModel))
        }
        return SonioxTTSSelection(model: resolvedModel, voice: voice)
    }

    /// Resolves built-in and account voices without ever changing provider.
    /// Missing, deleted, failed and not-yet-computed clones explicitly fall back to Maya.
    public static func resolvedVoice(
        voiceID: String?,
        accountVoices: [SonioxTTSAccountVoice],
        lastKnownName: String? = nil
    ) -> SonioxTTSResolvedVoice {
        if let voiceID, let builtIn = voice(forID: voiceID) {
            return SonioxTTSResolvedVoice(
                apiVoiceID: builtIn.apiVoiceName,
                providerVoiceID: builtIn.providerVoiceID,
                displayName: builtIn.displayName,
                accountVoice: nil,
                fallbackReason: nil
            )
        }

        let requestedID = voiceID.map(normalizedUnscopedVoiceID)
        if let requestedID,
           let accountVoice = accountVoices.first(where: { $0.id.caseInsensitiveCompare(requestedID) == .orderedSame }) {
            if accountVoice.status(for: defaultModel) == .ready {
                return SonioxTTSResolvedVoice(
                    apiVoiceID: accountVoice.id,
                    providerVoiceID: accountVoice.providerVoiceID,
                    displayName: accountVoice.name,
                    accountVoice: accountVoice,
                    fallbackReason: nil
                )
            }
            return fallbackVoice(reason: .cloneNotReady(lastKnownName: accountVoice.name))
        }

        guard requestedID != nil else { return fallbackVoice(reason: nil) }
        return fallbackVoice(reason: .missingOrDeletedClone(lastKnownName: lastKnownName))
    }

    private static func normalizedVoiceID(_ id: String) -> String {
        normalizedUnscopedVoiceID(id).lowercased()
    }

    private static func normalizedUnscopedVoiceID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("soniox/") else { return trimmed }
        return String(trimmed.dropFirst("soniox/".count))
    }

    private static func fallbackVoice(reason: SonioxTTSVoiceFallbackReason?) -> SonioxTTSResolvedVoice {
        let voice = defaultVoice(for: defaultModel)
        return SonioxTTSResolvedVoice(
            apiVoiceID: voice.apiVoiceName,
            providerVoiceID: voice.providerVoiceID,
            displayName: voice.displayName,
            accountVoice: nil,
            fallbackReason: reason
        )
    }

    // Voice names, genders and accents mirror Soniox's built-in voice list; the
    // style is the closest match to each voice's published character description.
    private static let builtInVoices: [SonioxTTSVoice] = [
        voice("Maya", .female, .american, .clear),
        voice("Daniel", .male, .american, .professional),
        voice("Noah", .male, .american, .energetic),
        voice("Nina", .female, .american, .energetic),
        voice("Emma", .female, .american, .casual),
        voice("Jack", .male, .american, .warm),
        voice("Adrian", .male, .american, .deep),
        voice("Claire", .female, .american, .professional),
        voice("Grace", .female, .american, .warm),
        voice("Owen", .male, .american, .casual),
        voice("Mina", .female, .american, .clear),
        voice("Kenji", .male, .american, .professional),
        voice("Rafael", .male, .spanish, .clear),
        voice("Mateo", .male, .spanish, .warm),
        voice("Lucia", .female, .spanish, .professional),
        voice("Sofia", .female, .spanish, .warm),
        voice("Oliver", .male, .british, .warm),
        voice("Arthur", .male, .british, .deep),
        voice("Isla", .female, .british, .energetic),
        voice("Victoria", .female, .british, .professional),
        voice("Cooper", .male, .australian, .casual),
        voice("Mason", .male, .australian, .casual),
        voice("Ruby", .female, .australian, .energetic),
        voice("Elise", .female, .australian, .warm),
        voice("Arjun", .male, .indian, .deep),
        voice("Rohan", .male, .indian, .energetic),
        voice("Priya", .female, .indian, .warm),
        voice("Meera", .female, .indian, .professional)
    ]

    private static func voice(
        _ id: String,
        _ gender: SonioxTTSVoiceGender,
        _ accent: SonioxTTSVoiceAccent,
        _ style: SonioxTTSVoiceStyle
    ) -> SonioxTTSVoice {
        SonioxTTSVoice(id: id, gender: gender, accent: accent, style: style)
    }
}
