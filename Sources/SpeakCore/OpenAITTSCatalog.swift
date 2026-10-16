import Foundation

public enum OpenAITTSModel: String, CaseIterable, Codable, Hashable, Sendable {
    case mini = "gpt-4o-mini-tts"
    case standard = "tts-1"
    case highDefinition = "tts-1-hd"

    public var desktopModelIdentifier: String { OpenAITTSCatalog.voiceIDPrefix + rawValue }

    public var qualityIdentifier: String {
        quality.rawValue
    }

    public var quality: VoiceSynthesisQuality {
        switch self {
        case .mini: .standard
        case .standard: .high
        case .highDefinition: .highest
        }
    }

    public var displayName: String {
        switch self {
        case .mini: "GPT-4o mini TTS"
        case .standard: "TTS-1"
        case .highDefinition: "TTS-1 HD"
        }
    }

    public var costPerThousandCharacters: Decimal? {
        switch self {
        case .mini: nil // Text/audio token pricing cannot be inferred from character counts.
        case .standard: Decimal(string: "0.015")
        case .highDefinition: Decimal(string: "0.030")
        }
    }
}

public struct OpenAITTSVoice: Hashable, Sendable {
    public enum Trait: String, Sendable {
        case male, female, neutral, british, professional, deep, clear, warm, energetic, multilingual
    }

    public let id: String
    public let name: String
    public let traits: [Trait]
    public let supportsLegacyModels: Bool

    public init(id: String, name: String, traits: [Trait], supportsLegacyModels: Bool) {
        self.id = id
        self.name = name
        self.traits = traits
        self.supportsLegacyModels = supportsLegacyModels
    }

    public var providerVoiceID: String { OpenAITTSCatalog.voiceIDPrefix + id }

    public func supports(_ model: OpenAITTSModel) -> Bool {
        model == .mini || supportsLegacyModels
    }
}

/// Preserve the Mac catalogue's stored identifiers, order and traits. New API
/// voices are not an implicit rollout. The documented TTS-1/HD subset excludes
/// Ballad and Verse; other models never inherit this compatibility rule.
public enum OpenAITTSCatalog {
    public static let providerIdentifier = "openai"
    public static let voiceIDPrefix = "openai/"
    public static let credentialIdentifier = "openai.tts.apiKey"
    public static let defaultModel: OpenAITTSModel = .standard
    public static let models = OpenAITTSModel.allCases
    public static let voices: [OpenAITTSVoice] = [
        .init(id: "alloy", name: "Alloy", traits: [.neutral, .professional, .multilingual],
              supportsLegacyModels: true),
        .init(id: "ash", name: "Ash", traits: [.male, .warm, .multilingual], supportsLegacyModels: true),
        .init(id: "ballad", name: "Ballad", traits: [.neutral, .warm, .multilingual], supportsLegacyModels: false),
        .init(id: "coral", name: "Coral", traits: [.female, .warm, .multilingual], supportsLegacyModels: true),
        .init(id: "echo", name: "Echo", traits: [.male, .clear, .multilingual], supportsLegacyModels: true),
        .init(id: "fable", name: "Fable", traits: [.british, .professional, .multilingual],
              supportsLegacyModels: true),
        .init(id: "onyx", name: "Onyx", traits: [.male, .deep, .multilingual], supportsLegacyModels: true),
        .init(id: "nova", name: "Nova", traits: [.female, .energetic, .multilingual], supportsLegacyModels: true),
        .init(id: "sage", name: "Sage", traits: [.neutral, .professional, .multilingual], supportsLegacyModels: true),
        .init(id: "shimmer", name: "Shimmer", traits: [.female, .warm, .multilingual], supportsLegacyModels: true),
        .init(id: "verse", name: "Verse", traits: [.neutral, .clear, .multilingual], supportsLegacyModels: false)
    ]

    public static func voice(forID identifier: String) -> OpenAITTSVoice? {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return voices.first { $0.providerVoiceID == identifier || $0.id == identifier }
    }

    public static func voices(for model: OpenAITTSModel) -> [OpenAITTSVoice] {
        voices.filter { $0.supports(model) }
    }

    public static func model(forQualityIdentifier identifier: String) throws -> OpenAITTSModel {
        guard let model = models.first(where: { $0.qualityIdentifier == identifier }) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return model
    }
}
