import Foundation

/// The conventional offline Azure voices shared by desktop pickers.
/// A resource's own voice listing remains authoritative when available.
public struct AzureNeuralVoice: Identifiable, Hashable, Sendable {
    public enum Trait: String, Sendable {
        case female, male, american, british, australian, professional, casual, warm
    }

    public let shortName: String
    public let name: String
    public let traits: [Trait]
    public var id: String { AzureMAIVoiceCatalog.voiceIDPrefix + shortName }
}

public enum AzureNeuralVoiceCatalog {
    public static let voices: [AzureNeuralVoice] = [
        .init(shortName: "en-US-AriaNeural", name: "Aria", traits: [.female, .american, .professional]),
        .init(shortName: "en-US-GuyNeural", name: "Guy", traits: [.male, .american, .professional]),
        .init(shortName: "en-US-JennyNeural", name: "Jenny", traits: [.female, .american, .casual, .warm]),
        .init(shortName: "en-US-DavisNeural", name: "Davis", traits: [.male, .american, .professional]),
        .init(shortName: "en-GB-SoniaNeural", name: "Sonia", traits: [.female, .british, .professional]),
        .init(shortName: "en-GB-RyanNeural", name: "Ryan", traits: [.male, .british, .professional]),
        .init(shortName: "en-AU-NatashaNeural", name: "Natasha", traits: [.female, .australian, .professional])
    ]
}
