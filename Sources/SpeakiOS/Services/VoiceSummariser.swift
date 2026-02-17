#if os(iOS)
import Foundation
import SpeakCore

/// Summarises OpenClaw responses into concise, voice-friendly text.
/// Uses the same OpenRouter-based post-processing pipeline but with a
/// TTS-optimised system prompt that strips markdown, shortens responses,
/// and preserves key information.
@MainActor
public final class VoiceSummariser: ObservableObject {
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
    /// Uses OpenRouter API with the configured post-processing model.
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

        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Just Speak to It iOS", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 300,
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceSummariserError.apiError(statusCode: statusCode, message: body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
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
#endif
