import Foundation

/// Transfer metadata, not a second persisted selection or a catalogue of voices.
public enum VoiceSelectionPreference {
    public static let key = ApplicationPreferenceKey.defaultTTSVoice.rawValue
    /// Desktop-only transfer companion: the Mac scalar cannot express an explicit model.
    public static let modelKey = "desktopTTSModelID"
    public static let keys: Set<String> = [key, modelKey]

    public struct Update: Sendable {
        public let voiceID: String?
        public let modelID: String?

        public init(preferences: [String: AnyCodable]) throws {
            voiceID = try VoiceSelectionPreference.scalar(VoiceSelectionPreference.key, in: preferences)
            modelID = try VoiceSelectionPreference.scalar(VoiceSelectionPreference.modelKey, in: preferences)
        }
    }

    private static func scalar(_ key: String, in values: [String: AnyCodable]) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let raw) = value.storage else { throw DesktopConfigurationError.invalidField(key) }
        return raw
    }
}

extension DesktopSpeechVoice {
    public var transferVoiceID: String {
        if case .deepgram(let voice) = self { return voice.providerVoiceID }
        return id
    }

    /// Imported intent may migrate recognized aliases, but may never take a fallback.
    /// The incumbent `resolved` APIs retain their legacy native-settings behavior.
    public static func strictlyResolved(
        modelID: String?, voiceID: String?, accountInventory: VoiceAccountInventory? = nil
    ) throws -> Self {
        guard let voiceID, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let selected = try resolved(modelID: modelID, voiceID: voiceID, accountInventory: accountInventory)
        if case .deepgram(let voice) = selected {
            let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard model == nil || DeepgramTTSCatalog.model(forLegacyID: model) != nil
                || DeepgramSpeechCatalog.models.contains(where: { $0.id == model }) else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            var identifier = voiceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if identifier.hasPrefix("deepgram/") { identifier.removeFirst("deepgram/".count) }
            let original = DeepgramTTSCatalog.voice(forID: identifier)
            let migrated = DeepgramTTSCatalog.voices.contains {
                $0.id == voice.id && ($0.name.lowercased() == identifier || $0.name == original?.name)
            }
            guard identifier == voice.id || migrated else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
        }
        return selected
    }
}
