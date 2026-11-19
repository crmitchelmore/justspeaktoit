import Foundation

/// Canonical Auto-Clean instructions and preferences. Tail-window size is retained
/// for transfer compatibility; neither current host truncates the full transcript.
public enum LivePolishPolicy {
    public static let debounceMilliseconds = 500
    public static let minimumDeltaCharacters = 20
    public static let tailWindowCharacters = 600
    public static let skipPostProcessing = true
    public static let requestTimeout: Duration = .seconds(10)

    public static let systemPrompt = """
    You are a real-time transcription cleaner. You receive raw speech-to-text output.

    YOUR TASK: Fix only obvious errors in spelling, punctuation, and capitalization.

    RULES:
    - Output ONLY the cleaned text, nothing else
    - Preserve meaning exactly
    - Keep it fast - minimal changes only
    - Do not add or remove words
    - Do not add commentary
    """

    public static func userMessage(stableContext: String = "", text: String) -> String {
        stableContext.isEmpty ? "Clean this text:\n\(text)"
            : "[Context: ...\(stableContext)]\n\nClean this text:\n\(text)"
    }

    public static func model(configured: String, postProcessing: String) -> String {
        for value in [configured, postProcessing] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ModelCatalog.defaultFastTextModel
    }

    public static func shouldRequest(_ text: String, after previous: String, minimumDelta: Int) -> Bool {
        guard !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text), text != previous else { return false }
        // Replacements and retractions cannot be detected by length subtraction.
        return previous.isEmpty || !text.hasPrefix(previous) || text.count - previous.count >= minimumDelta
    }
}

public struct LivePolishPreferences: Equatable, Sendable {
    public let mode: SpeedModeID
    public let model: String
    public let debounceMilliseconds: Int
    public let minimumDeltaCharacters: Int
    public let skipPostProcessing: Bool

    public init(
        mode: SpeedModeID = .instant, model: String = "",
        debounceMilliseconds: Int = LivePolishPolicy.debounceMilliseconds,
        minimumDeltaCharacters: Int = LivePolishPolicy.minimumDeltaCharacters,
        skipPostProcessing: Bool = LivePolishPolicy.skipPostProcessing
    ) {
        self.mode = mode
        self.model = model
        self.debounceMilliseconds = debounceMilliseconds
        self.minimumDeltaCharacters = minimumDeltaCharacters
        self.skipPostProcessing = skipPostProcessing
    }
}

public enum LivePolishError: LocalizedError {
    case invalidConfiguration, unsupportedModel, missingCredential, invalidResponse, timedOut, cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Auto-Clean configuration is invalid. Original transcript retained."
        case .unsupportedModel: return "Auto-Clean is unavailable for the selected model. Original transcript retained."
        case .missingCredential: return "Auto-Clean needs the selected cleanup model's API key. Original retained."
        case .invalidResponse: return "Auto-Clean returned no usable assistant text. Original transcript retained."
        case .timedOut: return "Auto-Clean timed out. Original transcript retained."
        case .cancelled: return "Auto-Clean cancelled. Original transcript retained."
        }
    }
}
