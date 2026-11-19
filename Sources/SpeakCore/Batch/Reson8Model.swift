import Foundation

/// The Reson8 engines the app offers. Every catalogue ID sends its own `model`
/// query value and validates against the languages Reson8 documents for that
/// model, so a change to the server default never changes the engine behind an
/// ID. Rumble-2-Flash is not offered; see Docs/batch-transcription-providers.md.
public enum Reson8Model: String, CaseIterable, Sendable {
    case rumble2 = "rumble-2"
    case resonant1 = "resonant-1"

    public var batchID: String { "reson8/\(rawValue)" }
    public var liveID: String { "reson8/\(rawValue)-streaming" }

    /// Resolves a batch or live catalogue ID.
    public init?(modelID: String) {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = Self.allCases.first(where: { $0.batchID == identifier || $0.liveID == identifier }) else {
            return nil
        }
        self = model
    }

    public var displayName: String {
        switch self {
        case .rumble2: return "Reson8 Rumble-2"
        case .resonant1: return "Reson8 Resonant-1"
        }
    }

    private var coverage: String {
        switch self {
        case .rumble2: return "\(languageCodes.count) languages with Reson8's most accurate model, Rumble-2"
        case .resonant1: return "ten European languages with Reson8's Resonant-1 model"
        }
    }

    public var batchOption: ModelCatalog.Option {
        ModelCatalog.Option(
            id: batchID, displayName: displayName,
            description: "Recorded speech across \(coverage).", latencyTier: .medium
        )
    }

    public var liveOption: ModelCatalog.Option {
        ModelCatalog.Option(
            id: liveID, displayName: displayName + " (Streaming)",
            description: "Genuine live PCM streaming with interim and final transcripts across \(coverage).",
            latencyTier: .fast
        )
    }

    /// Codes from https://docs.reson8.dev/speech-to-text/features/languages/ (checked 2026-11-13).
    var languageCodes: Set<String> {
        switch self {
        case .rumble2:
            return [
                "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "ceb", "cs", "da", "de", "el", "en",
                "es", "et", "eu", "fa", "fi", "fil", "fr", "fy", "gl", "hi", "hr", "hu", "id", "is",
                "it", "ja", "jv", "ko", "lt", "lv", "mk", "mr", "ms", "mt", "nb", "nl", "pl", "pt",
                "ro", "ru", "sk", "sl", "sq", "sr", "sv", "ta", "th", "tr", "uk", "vi", "yue", "zh"
            ]
        case .resonant1:
            return ["de", "en", "es", "fr", "fy", "it", "nl", "pl", "pt", "sv"]
        }
    }

    /// The `language` hint to send, `nil` for Automatic. An explicit language
    /// this model does not support fails before any audio leaves the device.
    func language(_ language: String?) throws -> String? {
        guard let code = FileSpeechProvider.languageCode(language) else { return nil }
        guard languageCodes.contains(code) else { throw FileSpeechError.unsupportedLanguage(displayName, code) }
        return code
    }
}
