import Foundation
import SpeakCore

public enum DesktopVoiceEdit {
    public struct Request: Sendable {
        public let selection: String
        public let instruction: String
        public let model: String
        public let temperature: Double

        public init(selection: String, instruction: String, model: String, temperature: Double) {
            self.selection = selection
            self.instruction = instruction
            self.model = model
            self.temperature = temperature
        }
    }

    public static func rewrite(_ request: Request, apiKey: String) async throws -> String {
        try await rewrite(request, client: OpenRouterChatClient(apiKey: apiKey))
    }

    public static func rewrite(_ request: Request, client: any ChatLLMClient) async throws -> String {
        try Task.checkCancellation()
        let instruction = VoiceEditPolicy.normalizedInstruction(request.instruction)
        guard !request.selection.isEmpty, !instruction.isEmpty else {
            throw DesktopVoiceEditError.emptyInput
        }
        guard request.temperature.isFinite, (0...1).contains(request.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let response = try await client.sendChat(
            systemPrompt: VoiceEditPolicy.systemPrompt,
            messages: [.init(
                role: .user,
                content: VoiceEditPolicy.userMessage(selection: request.selection, instruction: instruction)
            )],
            model: request.model, temperature: request.temperature
        )
        try Task.checkCancellation()
        guard let reply = response.messages.last(where: { $0.role == .assistant }) else {
            throw OpenRouterClientError.invalidResponse
        }
        let text = VoiceEditPolicy.normalizedRewrite(
            reply.content, original: request.selection, instruction: instruction
        )
        guard !text.isEmpty else { throw OpenRouterClientError.invalidResponse }
        return text
    }
}

public enum DesktopVoiceEditError: LocalizedError {
    case emptyInput
    public var errorDescription: String? { "Select text and record a nonempty editing instruction." }
}
