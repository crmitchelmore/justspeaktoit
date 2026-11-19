import Foundation
import SpeakCore

/// The prompts a downloaded local model receives and the cleanup of what it
/// returns. Delegates to the shared `LocalCleanupPrompt`, which iOS uses too.
enum LocalPostProcessingPrompt {
  static func userPrompt(rawText: String) -> String {
    LocalCleanupPrompt.userMessage(transcript: rawText)
  }

  /// The user's prompt when it already extends the cleanup policy, otherwise
  /// the stock cleanup policy, followed by the local-engine constraint.
  static func systemPrompt(_ userSystemPrompt: String = "") -> String {
    LocalCleanupPrompt.systemPrompt(userSystemPrompt)
  }

  /// System prompt for the explicit-prompt path: the caller's prompt verbatim,
  /// with only the local-engine constraint appended.
  static func explicitSystemPrompt(_ systemPrompt: String) -> String {
    LocalCleanupPrompt.explicitSystemPrompt(systemPrompt)
  }

  /// The model's answer without any `<think>` block, closed or not.
  static func sanitizedModelOutput(_ output: String) -> String {
    LocalCleanupPrompt.strippingThinking(output)
  }
}
