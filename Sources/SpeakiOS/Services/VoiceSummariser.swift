import Foundation
import SpeakCore

/// Summarises OpenClaw responses into concise, voice-friendly text.
/// Uses the same OpenRouter-based post-processing pipeline but with a
/// TTS-optimised system prompt that strips markdown, shortens responses,
/// and preserves key information.
@MainActor
public final class VoiceSummariser {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The system prompt that instructs the LLM to produce voice-ready summaries.
    public static let systemPrompt = """
        You are a voice response summariser. Your job is to take an AI assistant's text response \
        and rewrite it into a form that sounds natural when spoken aloud via text-to-speech.

        Rules:
        - Remove ALL markdown formatting (headers, bold, italic, bullets, code fences, links)
        - Convert lists into flowing sentences
        - Keep the core information but be concise — aim for 2-4 sentences max
        - Use natural spoken language, not written style
        - If the response contains code or technical details, describe what it does briefly
        - Never say "here is a summary" or meta-commentary — just give the summarised content
        - Preserve any specific names, numbers, dates, or facts mentioned
        - If it's a short simple response already (under 50 words), return it as-is with only markdown stripped
        """

    /// Summarise a response for voice output.
    /// Uses the shared SpeakCore OpenRouter client with the configured
    /// post-processing model.
    public func summarise(
        _ text: String,
        apiKey: String,
        model: String = "openai/gpt-4o-mini"
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        // If it's already short and has no markdown, return as-is
        let wordCount = text.split(separator: " ").count
        let hasMarkdown = text.contains("```") || text.contains("**") || text.contains("##") || text.contains("- ")
        if wordCount < 50 && !hasMarkdown {
            return text
        }

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceSummariserError.apiError(statusCode: 401, message: "Missing OpenRouter API key")
        }

        let client = OpenRouterAPIClient(
            apiKey: apiKey,
            session: session,
            branding: OpenRouterBranding(
                title: "Just Speak to It iOS",
                referer: "https://github.com/crmitchelmore/justspeaktoit"
            )
        )

        let response: ChatResponse
        do {
            response = try await client.sendChat(
                systemPrompt: Self.systemPrompt,
                messages: [ChatMessage(role: .user, content: text)],
                model: model,
                temperature: 0.3,
                maxTokens: 300
            )
        } catch let error as OpenRouterClientError {
            switch error {
            case .httpStatus(let statusCode, let body):
                throw VoiceSummariserError.apiError(statusCode: statusCode, message: body)
            default:
                throw VoiceSummariserError.invalidResponse
            }
        } catch is DecodingError {
            throw VoiceSummariserError.invalidResponse
        }

        guard let content = response.messages.last(where: { $0.role == .assistant })?.content else {
            throw VoiceSummariserError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error

public enum VoiceSummariserError: LocalizedError {
    case apiError(statusCode: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let message):
            return "Summarisation error (\(code)): \(message)"
        case .invalidResponse:
            return "Invalid response from summarisation API"
        }
    }
}
