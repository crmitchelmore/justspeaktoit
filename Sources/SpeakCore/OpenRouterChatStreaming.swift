import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatStreamingError: LocalizedError {
    case invalidEvent, incomplete, rejectedCompletion, limitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidEvent: return "The cleanup stream returned an invalid event."
        case .incomplete: return "The cleanup stream ended without a complete response."
        case .rejectedCompletion: return "The cleanup provider did not complete the requested text."
        case .limitExceeded: return "The cleanup stream exceeded its bounded preview size."
        }
    }
}

/// The callback receives complete accumulated previews, not deltas or output authority.
extension OpenRouterChatClient {
    public static let maximumStreamingTextBytes = 65_536

    public func sendChatStreaming(
        systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double,
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> ChatResponse {
        try Task.checkCancellation()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterClientError.apiKeyMissing }
        var request = URLRequest(url: OpenRouterService.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        branding.apply(to: &request)
        request.httpBody = try JSONEncoder().encode(OpenRouterChatRequest(
            model: model, temperature: temperature,
            messages: OpenRouterChatRequest.messages(systemPrompt: systemPrompt, messages: messages),
            stream: true, maxTokens: nil
        ))
        let parser = OpenRouterCleanupStream(onUpdate: onUpdate)
        do {
            _ = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: 2 * 1_024 * 1_024, deadline: .seconds(60),
                onData: {
                    try parser.receive($0)
                    return parser.isComplete
                },
                accept: { http in
                    guard (200..<300).contains(http.statusCode) else {
                        throw OpenRouterClientError.httpStatus(http.statusCode, "<stream body omitted>")
                    }
                    guard http.mimeType?.lowercased() == "text/event-stream" else {
                        throw OpenRouterClientError.invalidResponse
                    }
                }
            )
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        let text = try parser.completedText()
        var conversation = systemPrompt.map { [ChatMessage(role: .system, content: $0)] } ?? []
        conversation += messages
        conversation.append(.init(role: .assistant, content: text))
        return ChatResponse(messages: conversation, finishReason: "stop", cost: nil, rawPayload: nil)
    }
}

/// Bounded UTF-8/SSE framing. Decode only complete lines, never a partial scalar.
final class OpenRouterCleanupStream: @unchecked Sendable {
    private let lock = NSLock()
    private var line = Data()
    private var fields: [String] = []
    private var fieldBytes = 0
    private var text = ""
    private var done = false
    private var stopped = false
    private var sawCR = false
    private var failure: Error?
    private let onUpdate: @Sendable (String) -> Void
    static let maximumTextBytes = OpenRouterChatClient.maximumStreamingTextBytes
    static let maximumEventBytes = 65_536

    init(onUpdate: @escaping @Sendable (String) -> Void) { self.onUpdate = onUpdate }
    var isComplete: Bool { lock.withLock { done && failure == nil } }

    func receive(_ data: Data) throws {
        let update = try lock.withLock { () throws -> String? in
            if let failure { throw failure }
            let previous = text
            do {
                for byte in data {
                    if byte == 10, sawCR { sawCR = false; continue }
                    sawCR = byte == 13
                    if byte == 10 || byte == 13 {
                        try consumeLine()
                    } else {
                        guard line.count < Self.maximumEventBytes else { throw ChatStreamingError.limitExceeded }
                        line.append(byte)
                    }
                }
            } catch {
                failure = error
                throw error
            }
            return previous == text ? nil : text
        }
        if let update { onUpdate(update) }
    }

    func completedText() throws -> String {
        try lock.withLock {
            if let failure { throw failure }
            guard done, stopped, line.isEmpty, fields.isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatStreamingError.incomplete
            }
            return text
        }
    }

    private func consumeLine() throws {
        guard let value = String(data: line, encoding: .utf8) else { throw ChatStreamingError.invalidEvent }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            guard !fields.isEmpty else { return }
            let payload = fields.joined(separator: "\n")
            fields.removeAll(keepingCapacity: true)
            fieldBytes = 0
            try consumeEvent(payload)
        } else if value.hasPrefix(":") {
            return
        } else if value.hasPrefix("data:") {
            guard !done else { throw ChatStreamingError.invalidEvent }
            let rest = value.dropFirst(5)
            let field = String(rest.first == " " ? rest.dropFirst() : rest)
            fieldBytes += field.utf8.count + 1
            guard fieldBytes <= Self.maximumEventBytes else { throw ChatStreamingError.limitExceeded }
            fields.append(field)
        }
    }

    private func consumeEvent(_ payload: String) throws {
        if payload == "[DONE]" {
            guard stopped else { throw ChatStreamingError.incomplete }
            done = true
            return
        }
        guard !done else { throw ChatStreamingError.invalidEvent }
        let chunk: OpenRouterStreamChunk
        do { chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: Data(payload.utf8)) } catch {
            throw ChatStreamingError.invalidEvent
        }
        guard chunk.error == nil else { throw ChatStreamingError.rejectedCompletion }
        guard let choices = chunk.choices else { throw ChatStreamingError.invalidEvent }
        // Providers may send a final usage-only chunk with no choices.
        if choices.isEmpty { return }
        guard choices.count == 1, let choice = choices.first,
              choice.index == nil || choice.index == 0 else { throw ChatStreamingError.invalidEvent }
        if let content = choice.delta?.content, !content.isEmpty {
            guard !stopped else { throw ChatStreamingError.invalidEvent }
            guard !content.contains("\0") else { throw ChatStreamingError.invalidEvent }
            guard content.utf8.count <= Self.maximumTextBytes - text.utf8.count else {
                throw ChatStreamingError.limitExceeded
            }
            text += content
        }
        if let finish = choice.finishReason {
            guard finish == "stop", !stopped else { throw ChatStreamingError.rejectedCompletion }
            stopped = true
        } else if choice.delta == nil {
            throw ChatStreamingError.invalidEvent
        }
    }
}

struct OpenRouterStreamChunkDelta: Decodable {
    let role: String?
    let content: String?
}

struct OpenRouterStreamChunkChoice: Decodable {
    let index: Int?
    let delta: OpenRouterStreamChunkDelta?
    let finishReason: String?
    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

struct OpenRouterStreamChunk: Decodable {
    let choices: [OpenRouterStreamChunkChoice]?
    let error: AnyCodable?
}
