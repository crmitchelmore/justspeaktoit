import SpeakCore
import Foundation

/// The prompt text shown by the Cleanup Context preview.
@MainActor
enum CleanupPromptPreview {
  /// Renders the Cleanup Context prompt preview.
  ///
  /// Pure so the preview can be exercised in tests: in particular the
  /// downloaded-local branch consumes `outputLanguage` exactly like the remote
  /// branch does, which is why the Output Language picker has to be reachable for
  /// both post-processing locations (issue #852).
  static func text(
    model: String,
    outputLanguage: String,
    lexiconRuleCount: Int,
    includeLexiconDirectives: Bool,
    includeContextTags: Bool
  ) -> String {
    if PostProcessingManager.isBuiltInLocalPostProcessingModel(model) {
      return """
      The built-in rules cleaner does not send a prompt.

      It runs deterministic local cleanup rules on the raw transcript. Lexicon directives and context tags apply to \
      remote models and downloaded local LLMs only.
      """
    }

    let rawLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let language: String
    if rawLanguage.uppercased() == "ENGB" || rawLanguage.lowercased() == "en_gb" {
      language = "British English"
    } else {
      language = rawLanguage
    }

    let effectiveSystemPrompt = TranscriptCleanupPolicy.systemPrompt(
      outputLanguage: language,
      lexiconDirectives: includeLexiconDirectives
        ? ["[Example: \(lexiconRuleCount) active correction rules will be inserted here]"]
        : [],
      lexiconContextTags: includeContextTags
        ? ["Tags will be inserted based on active app context"]
        : []
    )

    if PostProcessingManager.isDownloadedLocalPostProcessingModel(model) {
      let localUserPrompt = LocalPostProcessingPrompt.userPrompt(rawText: "{{RAW_TRANSCRIPT}}")
      return """
      System prompt sent to the local model:

      \(LocalPostProcessingPrompt.systemPrompt(effectiveSystemPrompt))

      User prompt sent to the local model:

      \(localUserPrompt)
      """
    }

    return """
    System prompt:

    \(effectiveSystemPrompt)

    User message preview:

    \(TranscriptCleanupPolicy.userMessage(transcript: "{{RAW_TRANSCRIPT}}"))
    """
  }
}
