import Foundation

/// The prompt pair and output rules for cleanup by a downloaded local
/// language model.
///
/// The user's post-processing prompt (`postProcessingSystemPrompt`, or a
/// profile override) is the model's system instruction, exactly as a remote
/// model receives it through `TranscriptCleanupPolicy`; only the local-engine
/// constraint is appended. The transcript travels in the same inert JSON user
/// message. Built-in rules cleanup never reads a prompt.
public enum LocalLanguageModelPrompt {
    /// Appended to every local system instruction: small local models drift
    /// into reasoning or questions far more often than hosted ones.
    public static let localEngineConstraint =
        "Local engine constraint: never enter thinking mode, emit <think> tags, include reasoning, or ask questions."

    public static func systemPrompt(customPrompt: String?, outputLanguage: String?) -> String {
        let base = TranscriptCleanupPolicy.systemPrompt(customBasePrompt: customPrompt, outputLanguage: outputLanguage)
        return base + "\n\n" + localEngineConstraint
    }

    public static func userMessage(transcript: String) -> String {
        TranscriptCleanupPolicy.userMessage(transcript: transcript)
    }

    /// An output budget that fits the transcript: about four tokens a word
    /// plus headroom, between 256 and 4,096 tokens.
    public static func maximumOutputTokens(for transcript: String) -> Int {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        return min(4_096, max(256, words * 4 + 256))
    }

    /// Removes reasoning blocks (closed, unclosed or a stray closing tag) and
    /// surrounding whitespace from a model response.
    public static func sanitizedOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<think\b[^>]*>.*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
