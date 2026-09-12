import Foundation

/// One xAI speech voice. The identifier is the `voice_id` request field, and
/// xAI treats it case-insensitively.
public struct XAITTSVoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// BCP-47 tag the account listing reports for the voice, when it reports one.
    public let language: String?

    public init(id: String, name: String, language: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
    }

    public var apiVoiceID: String { id }

    public var providerVoiceID: String { "\(XAITTSCatalog.voiceIDPrefix)\(id)" }

    public var displayName: String { name }
}

/// Canonical xAI text-to-speech catalogue.
///
/// xAI publishes **no model identifier** for speech generation: `POST /v1/tts`
/// takes no `model` field and the models page prices the capability as "Text to
/// Speech". The voice is the whole choice.
///
/// Only the two voice identifiers the capability documentation names literally
/// ship as presets. xAI hosts more, but the published page points at the
/// playground and at `GET /v1/tts/voices` for the list instead of enumerating
/// it, so the remainder is loaded from the account rather than guessed here —
/// an unrecognised `voice_id` is an HTTP 404, not a graceful fallback.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
/// (read 2026-09-10).
public enum XAITTSCatalog {
    /// Prefix that routes a stored voice identifier back to this provider.
    public static let voiceIDPrefix = "xai/"

    /// The service default, used when a request names no voice.
    public static let defaultVoiceID = "eve"

    public static let voices: [XAITTSVoice] = [
        XAITTSVoice(id: "eve", name: "Eve"),
        XAITTSVoice(id: "ara", name: "Ara")
    ]

    public static var defaultVoice: XAITTSVoice {
        voices.first ?? XAITTSVoice(id: defaultVoiceID, name: "Eve")
    }

    /// Strips the `xai/` routing prefix, leaving the raw `voice_id`.
    public static func apiVoiceID(forVoiceID voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(voiceIDPrefix) else { return trimmed }
        return String(trimmed.dropFirst(voiceIDPrefix.count))
    }

    public static func voice(forID voiceID: String) -> XAITTSVoice? {
        let identifier = apiVoiceID(forVoiceID: voiceID).lowercased()
        return voices.first { $0.id == identifier }
    }

    /// The `voice_id` a request should send.
    ///
    /// Unlike a provider with a closed voice list, an identifier that is not in
    /// the preset catalogue is passed through: it is very likely one of the
    /// account voices `listVoices()` discovered, and rewriting it to `eve`
    /// would silently speak in the wrong voice. An empty selection falls back
    /// to the documented default.
    public static func resolvedAPIVoiceID(forVoiceID voiceID: String) -> String {
        let identifier = apiVoiceID(forVoiceID: voiceID)
        return identifier.isEmpty ? defaultVoiceID : identifier.lowercased()
    }

    // MARK: - Languages

    /// The 21 language tags the documentation lists, `auto` included.
    public static let supportedLanguageTags: [String] = [
        "auto", "en", "ar-EG", "ar-SA", "ar-AE", "bn", "zh", "fr", "de", "hi",
        "id", "it", "ja", "ko", "pt-BR", "pt-PT", "ru", "es-MX", "es-ES", "tr", "vi"
    ]

    /// Resolves a Speak language selection (`en_GB`, `pt_BR`, `Automatic`) to a
    /// tag xAI documents.
    ///
    /// `language` is a required request field, so there is no "omit it" option:
    /// anything unrecognised becomes `auto`, which is what xAI provides for
    /// exactly this case.
    public static func languageTag(for selection: String?) -> String {
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.lowercased() != "automatic" else { return "auto" }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        if let exact = supportedLanguageTags.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        guard let primary = normalized.split(separator: "-").first else { return "auto" }
        if let match = supportedLanguageTags.first(where: {
            $0.caseInsensitiveCompare(String(primary)) == .orderedSame
        }) {
            return match
        }
        return "auto"
    }
}
