import Foundation

/// Direct file APIs with no asynchronous job to poll. StepAudio's SSE is a
/// response to a complete recording, not a live-microphone transport.
public enum FileSpeechProvider: String, CaseIterable, Sendable {
    case smallest
    case reson8
    case stepfun

    public static let reson8LiveID = Reson8Model.resonant1.liveID
    /// Resonant-1's wire value. Each Reson8 ID sends its own `Reson8Model`.
    public static let reson8WireModel = Reson8Model.resonant1.rawValue
    public static let reson8FinishBudget: TimeInterval = 5

    public var modelID: String {
        switch self {
        case .smallest: return "smallest/pulse-pro"
        case .reson8: return Reson8Model.resonant1.batchID
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
            website = "https://platform.stepfun.ai"
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
            return Reson8Model.resonant1.batchOption
        case .stepfun:
            name = "StepFun StepAudio 3 ASR Max"
            description = "Upload one recording for StepAudio 3 recognition with streamed text responses. "
                + "Not live microphone streaming. Uses the region saved with your StepFun key."
        }
        return ModelCatalog.Option(id: modelID, displayName: name, description: description, latencyTier: .medium)
    }

    /// Every batch model this provider serves; `modelID` is the first-shipped one.
    public var options: [ModelCatalog.Option] {
        self == .reson8 ? Reson8Model.allCases.map(\.batchOption) : [option]
    }

    public var modelIDs: [String] { options.map(\.id) }

    public static var batchOptions: [ModelCatalog.Option] { allCases.flatMap(\.options) }

    public static let reson8LiveOption = Reson8Model.resonant1.liveOption
    public static var reson8LiveOptions: [ModelCatalog.Option] { Reson8Model.allCases.map(\.liveOption) }

    public static func provider(for modelID: String) -> FileSpeechProvider? {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.modelIDs.contains(identifier) }
    }

    static func languageCode(_ language: String?) -> String? {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != "automatic", value.lowercased() != "auto" else { return nil }
        return value.localeLanguageCode
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
