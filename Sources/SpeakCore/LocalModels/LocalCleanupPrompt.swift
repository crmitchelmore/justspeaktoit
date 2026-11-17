import Foundation

/// The prompts a downloaded cleanup model receives and the handling of what it
/// returns, shared by macOS and iOS (Android mirrors it in `LlamaCppCleaner.kt`).
///
/// The SYSTEM message is the cleanup policy plus one constraint that keeps
/// small reasoning models from thinking aloud; the USER message is the
/// transcript wrapped as JSON data.
public enum LocalCleanupPrompt {
    public static let engineConstraint =
        "Local engine constraint: never enter thinking mode, emit <think> tags, include reasoning, or ask questions."

    public static func userMessage(transcript: String) -> String {
        TranscriptCleanupPolicy.userMessage(transcript: transcript)
    }

    /// The user's prompt when it already extends the cleanup policy, otherwise
    /// the stock cleanup policy, followed by the local-engine constraint.
    public static func systemPrompt(_ userSystemPrompt: String = "") -> String {
        let trimmed = userSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanupPolicy = trimmed.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt)
            ? trimmed
            : TranscriptCleanupPolicy.systemPrompt()
        return "\(cleanupPolicy)\n\n\(engineConstraint)"
    }

    /// System prompt for an explicit prompt pair: the caller's prompt
    /// verbatim, with only the local-engine constraint appended.
    public static func explicitSystemPrompt(_ systemPrompt: String) -> String {
        "\(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(engineConstraint)"
    }

    /// Nothing to clean: blank, or only Whisper's blank-audio marker. The
    /// model is not loaded for it.
    public static func isEmpty(_ transcript: String) -> Bool {
        transcript.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a reply thought aloud. Such a reply is rejected, not repaired.
    public static func containsThinking(_ reply: String) -> Bool {
        reply.range(of: "<think", options: .caseInsensitive) != nil
            || reply.range(of: "</think>", options: .caseInsensitive) != nil
    }

    /// The model's answer without any `<think>` block, closed or not.
    public static func strippingThinking(_ output: String) -> String {
        output
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The usable text of a reply, trimmed; empty means no usable answer.
    /// Small models sometimes echo the input's shape, so a reply that is
    /// exactly `{"transcript": "…"}` yields the string inside it.
    public static func unwrappedReply(_ reply: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1,
              let transcript = object["transcript"] as? String else {
            return text
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
