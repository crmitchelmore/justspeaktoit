import Foundation
import SpeakCore

extension DesktopPostProcessing {
    /// The existing cleanup adapters, with Auto-Clean's exact minimal prompt.
    /// Rules-only cleanup is not an LLM and is deliberately not an Auto-Clean route.
    public static func polishLive(
        text: String, model: String, apiKey: String, localLLM: (any DesktopLocalLLMEngine)? = nil
    ) async throws -> String {
        try await polishLive(
            text: text, model: model, localLLM: localLLM,
            client: OpenRouterChatClient(apiKey: apiKey)
        )
    }

    public static func polishLive(
        text: String, model: String, localLLM: (any DesktopLocalLLMEngine)?,
        client: any ChatLLMClient
    ) async throws -> String {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text) { return "" }
        let user = LivePolishPolicy.userMessage(text: text)
        let output: String
        switch mode(for: model) {
        case .localLLM:
            guard let localLLM else {
                throw LocalLLMError.runtimeUnavailable("This host has no downloaded-model cleanup adapter.")
            }
            output = try await localLLM.complete(
                modelIdentifier: model, systemPrompt: LivePolishPolicy.systemPrompt,
                userPrompt: user, temperature: 0
            )
        case .remote:
            let response = try await client.sendChat(
                systemPrompt: LivePolishPolicy.systemPrompt, messages: [.init(role: .user, content: user)],
                model: model, temperature: 0
            )
            guard let assistant = response.messages.last(where: { $0.role == .assistant }) else {
                throw LivePolishError.invalidResponse
            }
            output = assistant.content
        default: throw LivePolishError.unsupportedModel
        }
        try Task.checkCancellation()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(trimmed) else {
            throw LivePolishError.invalidResponse
        }
        return trimmed
    }
}
