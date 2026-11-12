import SpeakCore
import Foundation

/// Builds the cleanup system prompt from the user's settings, the active
/// profile's prompt override and the personal lexicon.
@MainActor
struct PostProcessingPromptBuilder {
  let settings: AppSettings
  let personalLexicon: PersonalLexiconService

  /// The prompt with no lexicon context: the configured base prompt (or the
  /// profile override) and the output language.
  func basePrompt(override: String?) -> String {
    TranscriptCleanupPolicy.systemPrompt(
      customBasePrompt: override,
      outputLanguage: Self.outputLanguage(settings.postProcessingOutputLanguage)
    )
  }

  /// The session prompt, adding the lexicon directives and context tags the
  /// user has enabled for the destination app.
  func systemPrompt(
    override: String?,
    context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?
  ) -> String {
    let directives = PersonalLexiconDirectives.build(
      rules: personalLexicon.rules, context: context, corrections: corrections
    )
    return TranscriptCleanupPolicy.systemPrompt(
      customBasePrompt: override,
      outputLanguage: Self.outputLanguage(settings.postProcessingOutputLanguage),
      lexiconDirectives: settings.postProcessingIncludeLexiconDirectives ? directives : [],
      lexiconContextTags: settings.postProcessingIncludeContextTags ? Array(context.tags) : []
    )
  }

  /// The output language the prompt names, or nil when none is configured.
  /// Accepts the legacy `ENGB` / `en_gb` aliases for British English.
  nonisolated static func outputLanguage(_ setting: String) -> String? {
    let language = setting.trimmingCharacters(in: .whitespacesAndNewlines)
    if language.uppercased() == "ENGB" || language.lowercased() == "en_gb" {
      return "British English"
    }
    return language.isEmpty ? nil : language
  }
}
