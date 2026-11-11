import Foundation

/// Direct file APIs with no asynchronous job to poll. StepAudio's SSE is a
/// response to a complete recording, not a live-microphone transport.
public enum FileSpeechProvider: String, CaseIterable, Sendable {
    case smallest
    case reson8
    case stepfun

    public static let reson8LiveID = "reson8/resonant-1-streaming"
    public static let reson8FinishBudget: TimeInterval = 5

    public var modelID: String {
        switch self {
        case .smallest: return "smallest/pulse-pro"
        case .reson8: return "reson8/resonant-1"
        case .stepfun: return "stepfun/stepaudio-3-asr-max"
        }
    }

    public var metadata: TranscriptionProviderMetadata {
        let name: String
        let website: String
        switch self {
        case .smallest:
            name = "Smallest AI"
            website = "https://app.smallest.ai/dashboard/api-keys"
        case .reson8:
            name = "Reson8"
            website = "https://console.reson8.dev"
        case .stepfun:
            name = "StepFun"
            website = "https://platform.stepfun.com"
        }
        return TranscriptionProviderMetadata(
            id: rawValue, displayName: name, systemImage: "waveform",
            website: website
        )
    }

    public var option: ModelCatalog.Option {
        let name: String
        let description: String
        switch self {
        case .smallest:
            name = "Smallest AI Pulse Pro"
            description = "English-only recorded speech. Automatic uses English; no live audio support."
        case .reson8:
            name = "Reson8 Resonant-1"
            description = "Recorded speech across ten European languages. Uses Reson8's server-selected engine; "
                + "the public API does not expose a base-model selector."
        case .stepfun:
            name = "StepFun StepAudio 3 ASR Max"
            description = "Upload one recording for StepAudio 3 recognition with streamed text responses. "
                + "Not live microphone streaming."
        }
        return ModelCatalog.Option(id: modelID, displayName: name, description: description, latencyTier: .medium)
    }

    public static var batchOptions: [ModelCatalog.Option] { allCases.map(\.option) }

    public static let reson8LiveOption = ModelCatalog.Option(
        id: reson8LiveID, displayName: "Reson8 Resonant-1 (Streaming)",
        description: "Genuine live PCM streaming with interim and final transcripts across ten European languages. "
            + "Uses Reson8's server-selected engine.",
        latencyTier: .fast
    )

    public static func provider(for modelID: String) -> FileSpeechProvider? {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.modelID == identifier }
    }

    static func languageCode(_ language: String?) -> String? {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != "automatic", value.lowercased() != "auto" else { return nil }
        return value.localeLanguageCode
    }

    static func reson8Language(_ language: String?) throws -> String? {
        guard let code = languageCode(language) else { return nil }
        guard ["de", "en", "es", "fr", "fy", "it", "nl", "pl", "pt", "sv"].contains(code) else {
            throw FileSpeechError.unsupportedLanguage("Reson8", code)
        }
        return code
    }
}

public enum FileSpeechError: LocalizedError, Equatable {
    case unsupportedModel(String)
    case unsupportedLanguage(String, String)
    case unsupportedFormat(String)
    case fileTooLarge
    case service(String)
    case missingCompletion(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model): return "Unsupported direct speech model: \(model)."
        case .unsupportedLanguage(let provider, let language):
            return "\(provider) does not support the selected language (\(language)). Choose a supported language."
        case .unsupportedFormat(let format): return "This speech service does not support \(format) audio."
        case .fileTooLarge: return "This speech upload exceeds the app's 25 MiB recording limit."
        case .service(let message): return "Speech recognition failed: \(message)"
        case .missingCompletion(let provider):
            return "\(provider) did not confirm transcription completion. The recording can be retried."
        }
    }
}
