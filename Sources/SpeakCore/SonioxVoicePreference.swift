import Foundation

/// Canonical transfer metadata; unknown strings survive transfer but never choose an operational region.
public enum SonioxVoicePreference {
    public static let regionKey = ApplicationPreferenceKey.sonioxTTSRegion.rawValue
    public static let languageKey = VoiceOutputLanguagePreference.key
    public static let keys: Set<String> = [regionKey, languageKey]
    public static let fields: [DesktopConfiguration.Field] = [
        .init(key: regionKey, title: "Soniox processing region (use its matching project key)", group: "Voice Output",
              kind: .choice(SonioxTTSRegion.allCases.map {
                  .init(value: $0.rawValue, title: $0.displayName)
              }), defaultValue: AnyCodable(.string(SonioxTTSRegion.unitedStates.rawValue))),
        VoiceOutputLanguagePreference.field
    ]

    public static func string(_ key: String, in values: [String: AnyCodable]) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value.storage,
              text.utf8.count <= 256,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DesktopConfigurationError.invalidField(key)
        }
        return text
    }

    public static func validateLanguage(_ value: String?) throws {
        let normalized = VoiceOutputLanguageCatalog.normalizedIdentifier(value)
        guard normalized != VoiceOutputLanguageCatalog.automaticIdentifier else { return }
        let code = SonioxTTSCatalog.requiredLanguageCode(normalized)
        guard VoiceOutputLanguageCatalog.options.contains(where: {
            $0.id != VoiceOutputLanguageCatalog.automaticIdentifier
                && SonioxTTSCatalog.requiredLanguageCode($0.id) == code
        }) else { throw DesktopSonioxSpeechError.unsupportedLanguage }
    }
}

extension DesktopConfiguration {
    /// Preserve unknown choice values rather than letting a native combo select a default.
    public func serializedChoices(for field: Field) -> String? {
        guard let choices = field.serializedChoices else { return nil }
        guard field.key == SonioxVoicePreference.regionKey
                || field.key == VoiceSynthesisPreference.quality.key.rawValue
                || field.key == ApplicationPreferenceKey.speedMode.rawValue,
              case .string(let saved) = value(for: field).storage,
              case .choice(let options) = field.kind,
              !options.contains(where: { $0.value == saved }) else { return choices }
        let reason: String
        switch field.key {
        case SonioxVoicePreference.regionKey:
            reason = "Unsupported stored region (preserved; choose a supported region to use Soniox)"
        case ApplicationPreferenceKey.speedMode.rawValue:
            reason = "Unsupported stored speed mode (preserved; choose Instant or Auto-Clean)"
        default:
            reason = "Unsupported stored quality (preserved; choose a supported quality to synthesize)"
        }
        return choices + "\n\(saved)\t\(reason)"
    }
}
