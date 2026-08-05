import Foundation

/// A language choice shared by every Just Speak to It surface.
public struct TranscriptionLanguageOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Canonical language catalogue and provider-facing preference semantics.
public enum TranscriptionLanguageCatalog {
    /// Stored when providers should detect the spoken language themselves.
    public static let automaticIdentifier = "automatic"

    public static let options: [TranscriptionLanguageOption] = [
        TranscriptionLanguageOption(id: automaticIdentifier, displayName: "Automatic"),
        TranscriptionLanguageOption(id: "en_US", displayName: "English (United States)"),
        TranscriptionLanguageOption(id: "en_GB", displayName: "English (United Kingdom)"),
        TranscriptionLanguageOption(id: "en_AU", displayName: "English (Australia)"),
        TranscriptionLanguageOption(id: "en_CA", displayName: "English (Canada)"),
        TranscriptionLanguageOption(id: "es_ES", displayName: "Spanish (Spain)"),
        TranscriptionLanguageOption(id: "es_MX", displayName: "Spanish (Mexico)"),
        TranscriptionLanguageOption(id: "fr_FR", displayName: "French (France)"),
        TranscriptionLanguageOption(id: "de_DE", displayName: "German (Germany)"),
        TranscriptionLanguageOption(id: "hi_IN", displayName: "Hindi (India)"),
        TranscriptionLanguageOption(id: "ja_JP", displayName: "Japanese (Japan)"),
        TranscriptionLanguageOption(id: "ko_KR", displayName: "Korean (South Korea)"),
        TranscriptionLanguageOption(id: "pt_BR", displayName: "Portuguese (Brazil)"),
        TranscriptionLanguageOption(id: "pt_PT", displayName: "Portuguese (Portugal)"),
        TranscriptionLanguageOption(id: "zh_CN", displayName: "Chinese (Simplified)"),
        TranscriptionLanguageOption(id: "zh_TW", displayName: "Chinese (Traditional)"),
        TranscriptionLanguageOption(id: "ar_SA", displayName: "Arabic (Saudi Arabia)"),
        TranscriptionLanguageOption(id: "ru_RU", displayName: "Russian (Russia)")
    ]

    /// Normalises missing and legacy blank values to Automatic while preserving
    /// explicit locale identifiers from earlier releases.
    public static func normalizedIdentifier(_ identifier: String?) -> String {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return automaticIdentifier
        }
        return identifier
    }

    /// Value passed to providers. `nil` requests provider-side detection.
    public static func providerLanguage(for identifier: String) -> String? {
        let normalized = normalizedIdentifier(identifier)
        return normalized == automaticIdentifier ? nil : normalized
    }

    /// Apple speech APIs require a concrete locale even when the preference is Automatic.
    public static func localeIdentifier(
        for identifier: String,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        providerLanguage(for: identifier) ?? systemLocaleIdentifier
    }
}
