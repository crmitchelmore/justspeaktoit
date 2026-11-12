import Foundation
import SpeakCore

/// The prompts a downloaded local model receives and the cleanup of what it
/// returns. Local engines get the shared cleanup policy plus one constraint
/// that keeps small reasoning models from thinking aloud.
enum LocalPostProcessingPrompt {
  static func userPrompt(rawText: String) -> String {
    TranscriptCleanupPolicy.userMessage(transcript: rawText)
  }

  /// The user's prompt when it already extends the cleanup policy, otherwise
  /// the stock cleanup policy, followed by the local-engine constraint.
  static func systemPrompt(_ userSystemPrompt: String = "") -> String {
    let trimmed = userSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanupPolicy = trimmed.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt)
      ? trimmed
      : TranscriptCleanupPolicy.systemPrompt()
    return """
    \(cleanupPolicy)

    \(localEngineConstraint)
    """
  }

  /// System prompt for the explicit-prompt path: the caller's prompt verbatim,
  /// with only the local-engine constraint appended.
  static func explicitSystemPrompt(_ systemPrompt: String) -> String {
    """
    \(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

    \(localEngineConstraint)
    """
  }

  /// The model's answer without any `<think>` block, closed or not.
  static func sanitizedModelOutput(_ output: String) -> String {
    output
      .replacingOccurrences(
        of: #"(?is)<think\b[^>]*>.*?</think>"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?is)<think\b[^>]*>.*"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?i)</think>"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let localEngineConstraint =
    "Local engine constraint: never enter thinking mode, emit <think> tags, include reasoning, or ask questions."
}
