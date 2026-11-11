import Foundation

/// What the OpenRouter client answers without a key for on-device and Apple
/// models: a placeholder transcript and a lightly tidied echo of the request.
enum OpenRouterLocalFallback {
    /// Models that may fall back instead of requiring the OpenRouter key.
    static func allows(model: String) -> Bool {
        if model.lowercased().hasPrefix("apple/") { return true }
        if model.lowercased().hasPrefix("local/") { return true }
        if model.lowercased() == "on-device" { return true }
        return false
    }

    static func transcription(of url: URL, model: String, duration: TimeInterval) -> TranscriptionResult {
        let text = "Transcription placeholder for \(url.lastPathComponent)"
        let segment = TranscriptionSegment(startTime: 0, endTime: duration, text: text)
        return TranscriptionResult(
            text: text,
            segments: [segment],
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    static func chatResponse(systemPrompt: String?, messages: [ChatMessage]) -> ChatResponse {
        let userText =
            messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""
        let processed = heuristicPostProcess(text: userText)

        var conversation: [ChatMessage] = []
        if let systemPrompt {
            conversation.append(ChatMessage(role: .system, content: systemPrompt))
        }
        conversation.append(contentsOf: messages)
        conversation.append(ChatMessage(role: .assistant, content: processed))

        return ChatResponse(
            messages: conversation, finishReason: "fallback-local", cost: nil, rawPayload: nil)
    }

    private static func heuristicPostProcess(text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let collapsed =
            trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return trimmed }

        var result = collapsed
        if let first = result.first {
            let uppercaseFirst = String(first).uppercased()
            result.replaceSubrange(result.startIndex...result.startIndex, with: uppercaseFirst)
        }

        if let last = result.last, !".!?".contains(last) {
            result.append(".")
        }

        return result
    }
}
