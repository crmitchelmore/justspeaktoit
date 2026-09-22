import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Explicit post-processing choices for desktop hosts. Remote cleanup is opt-in;
/// neither missing credentials nor an unsupported model selects a local substitute.
public enum DesktopPostProcessing {
    public enum Mode: String, Codable, Sendable {
        case disabled
        case remote
    }

    public struct Options: Codable, Equatable, Sendable {
        public var mode: Mode
        public var modelIdentifier: String
        public var customPrompt: String?
        public var outputLanguage: String?
        public var temperature: Double

        public init(
            mode: Mode = .disabled,
            modelIdentifier: String = ModelCatalog.defaultPostProcessingModel,
            customPrompt: String? = nil,
            outputLanguage: String? = nil,
            temperature: Double = 0.2
        ) {
            self.mode = mode
            self.modelIdentifier = modelIdentifier
            self.customPrompt = customPrompt
            self.outputLanguage = outputLanguage
            self.temperature = temperature
        }
    }

    public struct Outcome: Sendable {
        public let original: String
        public let processedText: String
        public let modelIdentifier: String?
        public let systemPrompt: String?
        public let userPrompt: String?
        public let response: ChatResponse?
    }

    public static var remoteModels: [ModelCatalog.Option] { ModelCatalog.cloudPostProcessing }

    public static func process(
        rawText: String,
        options: Options,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> Outcome {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return unchanged(original: rawText, processed: "")
        }
        guard options.mode == .remote else { return unchanged(original: rawText, processed: rawText) }
        let model = options.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteModels.contains(where: { $0.id == model }) else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        guard options.temperature.isFinite, (0...1).contains(options.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let systemPrompt = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt,
            outputLanguage: options.outputLanguage
        )
        let userPrompt = TranscriptCleanupPolicy.userMessage(transcript: rawText)
        let response = try await OpenRouterChatClient(apiKey: apiKey, session: session).sendChat(
            systemPrompt: systemPrompt,
            messages: [.init(role: .user, content: userPrompt)],
            model: model,
            temperature: options.temperature
        )
        try Task.checkCancellation()
        guard let assistant = response.messages.last(where: { $0.role == .assistant }),
              !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterClientError.invalidResponse
        }
        return Outcome(
            original: rawText,
            processedText: assistant.content,
            modelIdentifier: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            response: response
        )
    }

    private static func unchanged(original: String, processed: String) -> Outcome {
        Outcome(
            original: original, processedText: processed, modelIdentifier: nil,
            systemPrompt: nil, userPrompt: nil, response: nil
        )
    }
}

public enum DesktopPostProcessingError: LocalizedError {
    case unsupportedModel
    case invalidTemperature

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "Choose a supported remote post-processing model."
        case .invalidTemperature:
            return "Post-processing temperature must be between 0 and 1."
        }
    }
}
