import Foundation

/// The Mac-compatible language preference is shared by Gemini and Soniox.
/// Presentation never validates or replaces the stored value.
public enum VoiceOutputLanguagePreference {
    public static let key = ApplicationPreferenceKey.ttsLanguage.rawValue
    public static let field = DesktopConfiguration.Field(
        key: key, title: "Voice language (Gemini / Soniox; automatic or locale)",
        group: "Voice Output", kind: .text,
        defaultValue: AnyCodable(.string(VoiceOutputLanguageCatalog.automaticIdentifier)))

    public static func title(for voice: DesktopSpeechVoice?) -> String {
        switch voice {
        case .gemini?: "Gemini voice language (automatic or locale, e.g. en_GB)"
        case .soniox?: "Soniox voice language (automatic or locale, e.g. en_GB)"
        case nil: "Voice language (stored; selected voice is unavailable)"
        default: "Voice language (stored; not used by this provider)"
        }
    }
}
