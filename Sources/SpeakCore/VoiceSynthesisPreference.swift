import Foundation

public enum VoiceSynthesisPreference: CaseIterable, Sendable {
    case speed, pitch, useSSML

    public var key: ApplicationPreferenceKey {
        switch self {
        case .speed: return .ttsSpeed
        case .pitch: return .ttsPitch
        case .useSSML: return .ttsUseSSML
        }
    }

    public var field: DesktopConfiguration.Field {
        switch self {
        case .speed:
            return .init(key: key.rawValue, title: "Speech speed", group: "Voice Output",
                         kind: .number(VoiceSynthesisOptions.speedRange),
                         defaultValue: AnyCodable(.double(VoiceSynthesisOptions.defaultSpeed)))
        case .pitch:
            return .init(key: key.rawValue, title: "Speech pitch (whole semitones)", group: "Voice Output",
                         kind: .number(VoiceSynthesisOptions.pitchRange),
                         defaultValue: AnyCodable(.double(VoiceSynthesisOptions.defaultPitch)))
        case .useSSML:
            return .init(key: key.rawValue, title: "Use SSML", group: "Voice Output", kind: .boolean,
                         defaultValue: AnyCodable(.bool(VoiceSynthesisOptions.defaultUseSSML)))
        }
    }
}

/// Validates incoming scalars without changing absent or existing stored material.
public struct VoiceSynthesisPreferenceUpdate: Sendable {
    public let speed: Double?
    public let pitch: Double?
    public let useSSML: Bool?

    public init(preferences: [String: AnyCodable]) throws {
        speed = try Self.number(.speed, in: preferences)
        pitch = try Self.number(.pitch, in: preferences)
        if let value = preferences[VoiceSynthesisPreference.useSSML.key.rawValue] {
            guard case .bool(let enabled) = value.storage else {
                throw DesktopConfigurationError.invalidField(VoiceSynthesisPreference.useSSML.field.title)
            }
            useSSML = enabled
        } else { useSSML = nil }
        _ = try VoiceSynthesisOptions(
            speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
            pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
            useSSML: useSSML ?? VoiceSynthesisOptions.defaultUseSSML
        )
    }

    private static func number(
        _ preference: VoiceSynthesisPreference, in values: [String: AnyCodable]
    ) throws -> Double? {
        guard let value = values[preference.key.rawValue] else { return nil }
        switch value.storage {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: throw DesktopConfigurationError.invalidField(preference.field.title)
        }
    }
}

extension DesktopConfiguration {
    public static let voiceSynthesisTransferFields = VoiceSynthesisPreference.allCases.map(\.field)
    public static let voiceSynthesisTransferKeys = Set(VoiceSynthesisPreference.allCases.map { $0.key.rawValue })
    public static let voiceTransferKeys = voiceGenerationTransferKeys.union(voiceSynthesisTransferKeys)
}
