import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

public enum OpenRouterClientError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case httpStatus(Int, String)
    case audioFileTooLarge(fileSize: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "OpenRouter API key is missing."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let code, let body):
            return "OpenRouter responded with status \(code): \(body)"
        case .audioFileTooLarge(let fileSize, let limit):
            let fileSizeDescription = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            let limitDescription = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "Audio file is too large for OpenRouter reprocessing "
                + "(\(fileSizeDescription), limit \(limitDescription))."
        }
    }
}

// MARK: - Branding

/// Attribution headers OpenRouter uses to identify the calling app
/// (`X-Title` / `HTTP-Referer`). Never carries credentials.
public struct OpenRouterBranding: Sendable {
    public let title: String
    public let referer: String

    public init(title: String, referer: String) {
        self.title = title
        self.referer = referer
    }

    public static let platformDefault: OpenRouterBranding = {
        #if os(iOS)
        OpenRouterBranding(
            title: "Just Speak to It (iOS)",
            referer: "https://github.com/crmitchelmore/justspeaktoit"
        )
        #elseif os(Windows)
        OpenRouterBranding(
            title: "Just Speak to It (Windows)",
            referer: "https://github.com/crmitchelmore/justspeaktoit"
        )
        #else
        OpenRouterBranding(title: "SpeakApp (macOS)", referer: "https://github.com/speak")
        #endif
    }()
}

/// Shared service location for chat, streaming and inline-audio requests.
enum OpenRouterService {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
}

extension OpenRouterBranding {
    func apply(to request: inout URLRequest) {
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(referer, forHTTPHeaderField: "Referer")
    }
}

/// Portable, one-shot OpenRouter chat transport. Missing credentials always fail;
/// local cleanup is a separate, explicit product choice rather than an HTTP fallback.
public actor OpenRouterChatClient: ChatLLMClient {
    private let apiKey: String
    private let session: URLSession
    private let branding: OpenRouterBranding

    public init(
        apiKey: String,
        session: URLSession = .shared,
        branding: OpenRouterBranding = .platformDefault
    ) {
        self.apiKey = apiKey
        self.session = session
        self.branding = branding
    }

    public func sendChat(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double
    ) async throws -> ChatResponse {
        try await sendChat(
            systemPrompt: systemPrompt, messages: messages, model: model,
            temperature: temperature, maxTokens: nil
        )
    }

    public func sendChat(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        maxTokens: Int?
    ) async throws -> ChatResponse {
        try Task.checkCancellation()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterClientError.apiKeyMissing }
        let payload = OpenRouterChatRequest(
            model: model,
            temperature: temperature,
            messages: OpenRouterChatRequest.messages(systemPrompt: systemPrompt, messages: messages),
            stream: nil,
            maxTokens: maxTokens
        )
        var request = URLRequest(url: OpenRouterService.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        branding.apply(to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OpenRouterClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "<no-body>")
        }
        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        return Self.chatResponse(from: decoded, data: data, systemPrompt: systemPrompt, messages: messages)
    }

    private static func chatResponse(
        from decoded: OpenRouterChatResponse,
        data: Data,
        systemPrompt: String?,
        messages: [ChatMessage]
    ) -> ChatResponse {
        let assistantMessages = decoded.choices.compactMap { choice in
            choice.message.map { ChatMessage(role: .assistant, content: $0.content) }
        }
        let cost = decoded.usage.map { usage in
            ChatCostBreakdown(
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                totalCost: Decimal(usage.promptTokens + usage.completionTokens) / 1_000_000,
                currency: "USD"
            )
        }
        var conversation: [ChatMessage] = []
        if let systemPrompt { conversation.append(ChatMessage(role: .system, content: systemPrompt)) }
        conversation.append(contentsOf: messages)
        conversation.append(contentsOf: assistantMessages)
        return ChatResponse(
            messages: conversation,
            finishReason: decoded.choices.first?.finishReason ?? "stop",
            cost: cost,
            rawPayload: String(data: data, encoding: .utf8)
        )
    }
}

// MARK: - Shared wire models

struct OpenRouterChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let messages: [Message]
    let stream: Bool?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case messages
        case stream
        case maxTokens = "max_tokens"
    }
}

struct OpenRouterChatResponseChoiceMessage: Decodable {
    let role: String?
    let content: String
}

struct OpenRouterChatResponseChoice: Decodable {
    let index: Int?
    let finishReason: String?
    let message: OpenRouterChatResponseChoiceMessage?

    enum CodingKeys: String, CodingKey {
        case index
        case finishReason = "finish_reason"
        case message
    }
}

struct OpenRouterChatUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

struct OpenRouterChatResponse: Decodable {
    let choices: [OpenRouterChatResponseChoice]
    let usage: OpenRouterChatUsage?
}

extension OpenRouterChatRequest {
    static func messages(systemPrompt: String?, messages: [ChatMessage]) -> [Message] {
        var payload: [Message] = []
        if let systemPrompt { payload.append(.init(role: "system", content: systemPrompt)) }
        payload += messages.map { .init(role: $0.role.rawValue, content: $0.content) }
        return payload
    }
}
