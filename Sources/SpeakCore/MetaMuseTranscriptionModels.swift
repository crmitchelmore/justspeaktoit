import Foundation

/// Shared support for Meta Model API's dedicated speech-to-text endpoints.
/// This deliberately does not use the OpenAI-compatible text-model surface.
public enum MetaMuseVoiceTranscribe {
    public static let providerID = "meta"
    public static let modelID = "muse-voice-transcribe-1.0"
    public static let liveCatalogID = "meta/\(modelID)-streaming"
    public static let batchCatalogID = "meta/\(modelID)"
    public static let realtimeURL = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    public static let transcribeURL = URL(string: "https://api.meta.ai/v1/asr/transcribe")!
    public static let maximumAudioDuration: TimeInterval = 600
    public static let maximumRequestBytes = 32 * 1_024 * 1_024

    /// Meta accepts language names rather than BCP-47 codes. Unknown locales
    /// are omitted so the model can use automatic language detection.
    public static func languageBias(for language: String?) -> [String] {
        guard let language else { return [] }
        let code = language
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        let names: [String: String] = [
            "ar": "Arabic", "bn": "Bengali", "nl": "Dutch", "en": "English",
            "fr": "French", "de": "German", "he": "Hebrew", "hi": "Hindi",
            "id": "Indonesian", "it": "Italian", "ja": "Japanese", "kn": "Kannada",
            "ko": "Korean", "ms": "Malay", "zh": "Mandarin Chinese", "mr": "Marathi",
            "pl": "Polish", "pt": "Portuguese", "es": "Spanish", "fil": "Tagalog",
            "tl": "Tagalog", "ta": "Tamil", "te": "Telugu", "th": "Thai",
            "tr": "Turkish", "vi": "Vietnamese"
        ]
        return names[code].map { [$0] } ?? []
    }

    /// Parses comma/newline-separated recognition terms into Meta's keyword array.
    public static func keywords(from rawValue: String) -> [String] {
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 100 }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(100)
            .map { $0 }
    }
}
