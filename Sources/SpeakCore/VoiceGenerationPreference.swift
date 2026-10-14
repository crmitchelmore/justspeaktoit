import Foundation

public enum VoiceGenerationPreference: RawRepresentable, CaseIterable, Sendable {
    case autoPlay
    case saveToRecordings

    public var rawValue: String {
        switch self {
        case .autoPlay: return ApplicationPreferenceKey.ttsAutoPlay.rawValue
        case .saveToRecordings: return ApplicationPreferenceKey.ttsSaveToDirectory.rawValue
        }
    }

    public init?(rawValue: String) {
        switch ApplicationPreferenceKey(rawValue: rawValue) {
        case .ttsAutoPlay: self = .autoPlay
        case .ttsSaveToDirectory: self = .saveToRecordings
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .autoPlay: return "Automatically play generated speech"
        case .saveToRecordings: return "Save generated speech to recordings"
        }
    }

    public var defaultValue: Bool {
        switch self {
        case .autoPlay: return SpeechGenerationDefaults.autoPlay
        case .saveToRecordings: return SpeechGenerationDefaults.saveToRecordings
        }
    }

    public func value(in preferences: [String: AnyCodable]) throws -> Bool? {
        guard let value = preferences[rawValue] else { return nil }
        guard case .bool(let enabled) = value.storage else {
            throw DesktopConfigurationError.invalidField(title)
        }
        return enabled
    }
}

extension DesktopConfiguration {
    /// Voice has its own native editor and persisted model, not dictation-dialog rows.
    public static let voiceGenerationTransferFields = VoiceGenerationPreference.allCases.map {
        Field(key: $0.rawValue, title: $0.title, group: "Voice Output", kind: .boolean,
              defaultValue: AnyCodable(.bool($0.defaultValue)))
    }

    public static let voiceGenerationTransferKeys = Set(VoiceGenerationPreference.allCases.map(\.rawValue))
}
