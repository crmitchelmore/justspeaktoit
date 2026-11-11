import Foundation

/// The streaming chat request `OpenRouterAPIClient` sends and the SSE lines
/// it reads back as text deltas.
enum OpenRouterStreamingChat {
    static func request(
        apiKey: String,
        branding: OpenRouterBranding,
        messages: [OpenRouterChatRequest.Message],
        model: String,
        temperature: Double
    ) throws -> URLRequest {
        let target = try ChatCompletionTarget.resolve(model)
        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if target.isOpenRouter { branding.apply(to: &request) }

        let payload = OpenRouterChatRequest(
            model: model,
            temperature: temperature,
            messages: messages,
            stream: true,
            maxTokens: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    /// Extracts the delta content from a single OpenRouter SSE line, or nil
    /// when the line carries no textual delta (comments, empty lines, `[DONE]`).
    static func content(fromSSELine line: String) -> String? {
        guard !line.isEmpty, line.hasPrefix("data: ") else { return nil }

        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]", let data = jsonString.data(using: .utf8) else { return nil }

        guard let chunk = try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: data),
              let delta = chunk.choices?.first?.delta,
              let content = delta.content, !content.isEmpty else {
            return nil
        }
        return content
    }

    /// True when the line is the `data: [DONE]` terminator.
    static func isTerminator(_ line: String) -> Bool {
        line == "data: [DONE]"
    }
}
