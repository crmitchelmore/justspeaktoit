import Foundation

/// Canonical models extracted from the Mac client. v4 remains dialogue-only;
/// its documented endpoint is not interchangeable with text-to-speech.
public enum ElevenLabsTTSModels {
    public struct Model: Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let maximumCharacters: Int
        public var desktopModelIdentifier: String { ElevenLabsTTSCatalog.voiceIDPrefix + id }
    }

    public static let elevenV4 = Model(
        id: "eleven_v4", displayName: "Eleven v4 (most expressive)", maximumCharacters: 10_000)
    public static let elevenV3 = Model(id: "eleven_v3", displayName: "Eleven v3", maximumCharacters: 5_000)
    public static let multilingualV2 = Model(
        id: "eleven_multilingual_v2", displayName: "Eleven Multilingual v2", maximumCharacters: 10_000)
    public static let flashV25 = Model(
        id: "eleven_flash_v2_5", displayName: "Eleven Flash v2.5 (fastest)", maximumCharacters: 40_000)
    public static let all = [elevenV4, elevenV3, multilingualV2, flashV25]
    public static let dialogueOnlyModelIDs: Set<String> = [elevenV4.id]
    public static let dialogueCharacterLimit = 2_000
    public static let dialogueFallback = elevenV3
    public static let deprecatedReplacements = [
        "eleven_turbo_v2_5": flashV25.id,
        "eleven_turbo_v2": flashV25.id,
        "eleven_multilingual_v1": multilingualV2.id
    ]

    public static func current(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return deprecatedReplacements[trimmed] ?? trimmed
    }

    public static func model(forID identifier: String) -> Model? {
        let raw = identifier.hasPrefix(ElevenLabsTTSCatalog.voiceIDPrefix)
            ? String(identifier.dropFirst(ElevenLabsTTSCatalog.voiceIDPrefix.count)) : identifier
        let canonical = current(raw)
        return all.first { $0.id == canonical }
    }

    public static func model(for quality: VoiceSynthesisQuality) -> Model {
        switch quality {
        case .standard: flashV25
        case .high: multilingualV2
        case .highest: elevenV4
        }
    }
}

public struct ElevenLabsTTSVoice: Hashable, Sendable {
    public enum Trait: String, Hashable, Sendable {
        case female, male, american, british, professional, clear, multilingual, deep, warm, energetic, casual
    }
    public let id: String
    public let displayName: String
    public let traits: [Trait]
    public var providerVoiceID: String { ElevenLabsTTSCatalog.voiceIDPrefix + id }
}

/// The Mac's offline presets, not a claim that every account has every voice.
public enum ElevenLabsTTSCatalog {
    public static let providerIdentifier = "elevenlabs"
    public static let voiceIDPrefix = "elevenlabs/"
    public static let credentialIdentifier = "elevenlabs.apiKey"
    public static let defaultModel = ElevenLabsTTSModels.multilingualV2
    public static let voices: [ElevenLabsTTSVoice] = [
        .init(id: "21m00Tcm4TlvDq8ikWAM", displayName: "Rachel",
              traits: [.female, .american, .professional, .clear, .multilingual]),
        .init(id: "pNInz6obpgDQGcFmaJgB", displayName: "Adam",
              traits: [.male, .american, .deep, .professional, .multilingual]),
        .init(id: "EXAVITQu4vr4xnSDxMaL", displayName: "Sarah",
              traits: [.female, .american, .warm, .multilingual]),
        .init(id: "ErXwobaYiN019PkySvjV", displayName: "Antoni",
              traits: [.male, .american, .clear, .multilingual]),
        .init(id: "TxGEqnHWrfWFTfGW9XjX", displayName: "Josh",
              traits: [.male, .american, .energetic, .multilingual]),
        .init(id: "MF3mGyEYCl7XYWbV9V6O", displayName: "Elli",
              traits: [.female, .american, .warm, .casual]),
        .init(id: "D38z5RcWu1voky8WS1ja", displayName: "Fin", traits: [.male, .british, .professional]),
        .init(id: "jBpfuIE2acCO8z3wKNLl", displayName: "Gigi", traits: [.female, .american, .energetic, .casual])
    ]
    public static let legacyVoiceIdentifiers = [
        "elevenlabs/rachel": voices[0].providerVoiceID,
        "elevenlabs/adam": voices[1].providerVoiceID,
        "elevenlabs/bella": voices[2].providerVoiceID
    ]

    public static func voice(forID identifier: String) -> ElevenLabsTTSVoice? {
        let canonical = legacyVoiceIdentifiers[identifier] ?? identifier
        return voices.first { $0.providerVoiceID == canonical || $0.id == canonical }
    }
}
