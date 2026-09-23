import Foundation

/// Catalogue and upstream identifiers for Google's Gemini 3.5 Transcribe
/// models (issue #816).
///
/// Both models are in **public preview**. The catalogue has no availability
/// field, so preview status is carried in the display name and description and
/// neither model is ever a default or an automatic fallback.
///
/// The `google/` catalogue prefix is shared with the OpenRouter-routed
/// `google/gemini-2.0-flash-*` batch entries, so anything that decides "is this
/// served by Google directly?" must match the identifiers below rather than the
/// prefix alone.
public enum GeminiTranscribeModels {
    // MARK: - Catalogue identifiers

    /// Live streaming model id in `ModelCatalog.liveTranscription`.
    public static let liveCatalogID = "google/gemini-3.5-transcribe-live"

    /// Prerecorded model id in `ModelCatalog.batchTranscription`.
    public static let batchCatalogID = "google/gemini-3.5-transcribe"

    // MARK: - Upstream model names

    /// Upstream model id for the Live API. Sent as `models/<name>`.
    public static let liveAPIName = "gemini-3.5-transcribe-live"

    /// Upstream model id for the Interactions API.
    public static let batchAPIName = "gemini-3.5-transcribe"

    // MARK: - Endpoints

    public static let apiHost = "generativelanguage.googleapis.com"

    /// Interactions API endpoint used for prerecorded transcription.
    public static let interactionsURL =
        URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    /// Files API resumable-upload endpoint, used when the audio is too large
    /// to inline in the request.
    public static let fileUploadURL =
        URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!

    /// Status endpoint for one uploaded file. `name` is the resource name the
    /// upload response carries (`files/abc123`), which is what the Files API
    /// documents polling for the `ACTIVE` state.
    public static func fileStatusURL(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasPrefix("files/") ? trimmed : "files/\(trimmed)"
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/\(encoded)")
    }

    /// ListModels, used as a cheap credential probe.
    public static let listModelsURL =
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    /// Header name the Gemini API authenticates REST calls with.
    public static let apiKeyHeader = "x-goog-api-key"

    /// Provider name used in user-visible error copy.
    public static let providerDisplayName = "Google Gemini"

    /// Batch catalogue identifiers served by Google's own API rather than by
    /// OpenRouter. `ModelCredentialResolver` and the provider registry both key
    /// off this so the OpenRouter-routed `google/gemini-2.0-flash-*` entries
    /// keep requiring an OpenRouter key.
    public static let directBatchModelIDs: Set<String> = [batchCatalogID]

    // MARK: - Request shaping

    /// Maximum raw audio bytes sent inline. The Interactions API caps a request
    /// at 20 MB *after* base64 expansion (4/3), so this leaves headroom for the
    /// JSON envelope; larger recordings go through the Files API instead.
    public static let inlineAudioByteLimit = 13_000_000

    /// Upstream cap on custom-vocabulary phrases.
    public static let customVocabularyLimit = 1_000

    /// Normalises an app locale identifier (`en_GB`) to the BCP-47 spelling the
    /// Gemini API expects (`en-GB`). Returns `nil` when there is nothing usable,
    /// which the request shapers turn into automatic language detection.
    public static func languageCode(from identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        return normalized.isEmpty ? nil : normalized
    }

    /// The `languageCodes` / `language_codes` array for a locale. An empty
    /// array is the documented "detect automatically, allow code-switching"
    /// setting.
    public static func languageCodes(from identifier: String?) -> [String] {
        guard let code = languageCode(from: identifier) else { return [] }
        return [code]
    }

    /// The BCP-47 codes Gemini 3.5 Transcribe Live lists for
    /// `inputAudioTranscription.languageCodes`
    /// (ai.google.dev/gemini-api/docs/live-api/live-transcribe, read
    /// 2026-09-23). The Live model takes these region-qualified tags, not bare
    /// language codes; an empty list detects the language.
    public static let liveLanguageCodes: Set<String> = [
        "af-ZA", "am-ET", "ar-EG", "hy-AM", "as-IN", "az-AZ", "be-BY", "bn-BD", "bn-IN", "bs-BA", "bg-BG",
        "rup-BG", "my-MM", "yue-Hant-HK", "ca-ES", "ceb", "km-KH", "hr-HR", "cs-CZ", "da-DK", "nl-NL",
        "en-GB", "en-IN", "en-US", "et-EE", "fa-IR", "fil-PH", "fi-FI", "fr-FR", "gl-ES", "ka-GE", "de-DE",
        "el-GR", "gu-IN", "ha-NG", "he-IL", "hi-IN", "hu-HU", "is-IS", "id-ID", "it-IT", "ja-JP", "jv-ID",
        "kea-CV", "kn-IN", "kk-KZ", "ko-KR", "ky-KG", "lv-LV", "ln-CD", "lt-LT", "mk-MK", "ms-MY", "ml-IN",
        "mt-MT", "cmn-Hans-CN", "mr-IN", "mn-MN", "ne-NP", "nb-NO", "or-IN", "pl-PL", "pt-BR", "pt-PT",
        "pa-IN", "pa-Guru-IN", "ro-RO", "ru-RU", "sr-RS", "sd-Arab-IN", "sk-SK", "sl-SI", "es-419", "es-US",
        "sw-KE", "sv-SE", "tg-TJ", "te-IN", "th-TH", "tr-TR", "uk-UA", "uz-UZ", "vi-VN"
    ]

    /// Selections the Live list spells differently: Simplified Chinese in
    /// China is Mandarin (`cmn-Hans-CN`), and Mexico is in the Latin American
    /// region (`es-419`). Keys are lowercased tags.
    private static let liveLanguageAliases: [String: String] = [
        "zh-cn": "cmn-Hans-CN", "zh-hans-cn": "cmn-Hans-CN", "zh-hans": "cmn-Hans-CN", "es-mx": "es-419"
    ]

    /// Gemini 3.5 Transcribe Live's code for a Speak language selection
    /// (`en_GB` becomes `en-GB`), or `nil` for Automatic and for a language the
    /// Live model does not list, such as `en_AU` or `zh_TW`, which it then
    /// detects instead. The one mapping every platform's Live request uses.
    public static func liveLanguageCode(for selection: String?) -> String? {
        guard let language = TranscriptionLanguageCatalog.providerLanguage(for: selection ?? "") else { return nil }
        // Locale identifiers may carry keywords (`en_GB@calendar=gregorian`).
        let base = language.split(separator: "@", maxSplits: 1).first.map(String.init) ?? language
        let tag = base.replacingOccurrences(of: "_", with: "-")
        if let alias = liveLanguageAliases[tag.lowercased()] { return alias }
        return liveLanguageCodes.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Trims a custom-vocabulary list to the documented bounds. Blank phrases
    /// are dropped so an empty lexicon never reaches the wire as `[""]`.
    public static func boundedCustomVocabulary(_ terms: [String]) -> [String] {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(customVocabularyLimit))
    }
}

/// Transcription mode supported by both Gemini 3.5 Transcribe surfaces.
///
/// `verbatim` returns exactly what was said; `smart` removes fillers and
/// applies formatting. The app defaults to `verbatim` because its own cleanup
/// and post-processing pipeline owns that step, and because `smart` cannot be
/// combined with word timestamps or diarization.
public enum GeminiTranscriptionMode: String, Sendable, Hashable {
    case verbatim
    case smart

    /// Wire spelling used by the Live API's `inputAudioTranscription.mode`.
    public var liveWireValue: String {
        switch self {
        case .verbatim: return "VERBATIM"
        case .smart: return "SMART"
        }
    }

    /// Wire spelling used by the Interactions API's `transcription_config.mode`.
    public var batchWireValue: String { self.rawValue }
}
