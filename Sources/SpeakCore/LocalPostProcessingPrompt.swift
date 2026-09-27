import Foundation

/// Prompt framing and output cleanup for downloaded local cleanup models, shared
/// by every host that runs them through llama.cpp.
public enum LocalPostProcessingPrompt {
    /// Appended to every local system instruction: small hybrid reasoning
    /// models otherwise think aloud or ask questions instead of editing.
    public static let engineConstraint =
        "Local engine constraint: never enter thinking mode, emit <think> tags, include reasoning, or ask questions."

    /// The system instruction for a local model: the caller's prompt verbatim
    /// (for example `TranscriptCleanupPolicy.systemPrompt(customBasePrompt:)`
    /// built from the user's post-processing prompt), then the local-engine
    /// constraint.
    public static func systemInstruction(_ systemPrompt: String) -> String {
        """
        \(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

        \(engineConstraint)
        """
    }

    /// Removes any reasoning block a model emitted despite the constraint,
    /// including an unterminated one, and surrounding whitespace.
    public static func sanitizedOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The generation budget for a transcript: room to restate it with
    /// punctuation, bounded for small context windows.
    public static func maximumOutputTokens(for rawText: String) -> Int {
        let words = rawText.split(whereSeparator: { $0.isWhitespace }).count
        return min(8_192, max(1_024, words * 4 + 512))
    }
}
