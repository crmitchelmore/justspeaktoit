import Foundation
import os.log

struct PostProcessingOutcome {
  let original: String
  let processed: String
  let response: ChatResponse?
  let systemPrompt: String
}

@MainActor
final class PostProcessingManager: ObservableObject {
  private let client: ChatLLMClient
  private let settings: AppSettings
  private let personalLexicon: PersonalLexiconService
  private let log = Logger(subsystem: "com.github.speakapp", category: "PostProcessing")

  static let defaultPrompt =
    "The following message is a raw transcription. Improve the transcription by fixing grammar, punctuation, and formatting while preserving the original meaning. Only ever return the processed transcription, no additional text."

  init(client: ChatLLMClient, settings: AppSettings, personalLexicon: PersonalLexiconService) {
    self.client = client
    self.settings = settings
    self.personalLexicon = personalLexicon
  }

  func process(
    rawText: String,
    context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?,
    onStreamingUpdate: ((String) -> Void)? = nil
  ) async -> Result<PostProcessingOutcome, Error> {
    guard settings.postProcessingEnabled else {
      return .success(
        .init(
          original: rawText,
          processed: rawText,
          response: nil,
          systemPrompt: basePrompt()
        )
      )
    }

    let systemPrompt = effectiveSystemPrompt(for: context, corrections: corrections)
    let model = settings.postProcessingModel.isEmpty
      ? "inception/mercury"
      : settings.postProcessingModel

    // Try streaming if enabled and client supports it
    if settings.postProcessingStreamingEnabled,
       let streamingClient = client as? StreamingChatLLMClient {
      do {
        var accumulated = ""
        let stream = streamingClient.sendChatStreaming(
          systemPrompt: systemPrompt,
          messages: [ChatMessage(role: .user, content: rawText)],
          model: model,
          temperature: settings.postProcessingTemperature
        )

        for try await chunk in stream {
          accumulated += chunk
          onStreamingUpdate?(accumulated)
        }

        let cleaned = accumulated.isEmpty ? rawText : accumulated
        return .success(
          .init(
            original: rawText,
            processed: cleaned,
            response: nil,
            systemPrompt: systemPrompt
          )
        )
      } catch {
        log.warning("Streaming failed, falling back to non-streaming: \(error.localizedDescription, privacy: .public)")
        // Fall through to non-streaming
      }
    }

    // Non-streaming fallback
    do {
      let response = try await client.sendChat(
        systemPrompt: systemPrompt,
        messages: [ChatMessage(role: .user, content: rawText)],
        model: model,
        temperature: settings.postProcessingTemperature
      )

      let cleaned =
        response.messages.last(where: { $0.role == .assistant })?.content
        ?? rawText
      return .success(
        .init(
          original: rawText,
          processed: cleaned,
          response: response,
          systemPrompt: systemPrompt
        )
      )
    } catch {
      log.error("Post-processing failed: \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  func hasRequiredAPIKey() async -> Bool {
    let configuredModel = settings.postProcessingModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = configuredModel.isEmpty ? "inception/mercury" : configuredModel

    guard let openRouterClient = client as? OpenRouterAPIClient else {
      return true
    }

    let requiresRemote = await openRouterClient.requiresRemoteAccess(for: resolvedModel)
    if !requiresRemote {
      return true
    }

    return await openRouterClient.hasStoredAPIKey()
  }

  private func basePrompt() -> String {
    let trimmed = settings.postProcessingSystemPrompt
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let basePrompt = trimmed.isEmpty ? Self.defaultPrompt : trimmed

    let rawLanguage = settings.postProcessingOutputLanguage
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let language: String
    if rawLanguage.uppercased() == "ENGB" || rawLanguage.lowercased() == "en_gb" {
      language = "British English"
    } else {
      language = rawLanguage
    }

    if !language.isEmpty {
      return "Always output using \(language). \(basePrompt)"
    }

    return basePrompt
  }

  private func effectiveSystemPrompt(
    for context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?
  ) -> String {
    var sections: [String] = []

    let directives = lexiconDirectives(for: context, corrections: corrections)
    if !directives.isEmpty && settings.postProcessingIncludeLexiconDirectives {
      let bulletList = directives.map { "- \($0)" }.joined(separator: "\n")
      let directiveSection = "Personal lexicon directives (internal use only):\n\(bulletList)\nApply these silently and never repeat or reference them in the response."
      sections.append(directiveSection)
    }

    var corePrompt = basePrompt()

    if !context.tags.isEmpty && settings.postProcessingIncludeContextTags {
      let tagList = context.tags.sorted().joined(separator: ", ")
      corePrompt += "\nContext tags: \(tagList)."
    }

    sections.append(corePrompt)

    // Add hardcoded final instruction
    if settings.postProcessingIncludeFinalInstruction {
      sections.append("Return only the processed text and nothing else. The following message is a raw transcript:")
    }

    return sections.joined(separator: "\n\n")
  }

  private func lexiconDirectives(
    for context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?
  ) -> [String] {
    var canonicalToAliases: [String: Set<String>] = [:]
    var canonicalConfidence: [String: PersonalLexiconConfidence] = [:]

    func merge(alias: String, canonical: String, confidence: PersonalLexiconConfidence) {
      canonicalToAliases[canonical, default: []].insert(alias)
      let existing = canonicalConfidence[canonical]
      canonicalConfidence[canonical] = maxConfidence(existing, confidence)
    }

    for rule in personalLexicon.activeRules(for: context) {
      for alias in rule.aliases {
        merge(alias: alias, canonical: rule.canonical, confidence: rule.confidence)
      }
    }

    if let corrections {
      for record in corrections.applied {
        merge(alias: record.alias, canonical: record.canonical, confidence: record.confidence)
      }
    }

    var directives: [String] = []

    for canonical in canonicalToAliases.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
      let aliases = canonicalToAliases[canonical]?.sorted() ?? []
      guard !aliases.isEmpty else { continue }
      let aliasList = aliases.joined(separator: ", ")
      let confidenceLabel = confidenceDescription(canonicalConfidence[canonical] ?? .medium)
      directives.append("Normalize \(aliasList) to \"\(canonical)\" (confidence: \(confidenceLabel)).")
    }

    if let suggestions = corrections?.suggestions, !suggestions.isEmpty {
      for suggestion in suggestions {
        let confidenceLabel = confidenceDescription(suggestion.confidence)
        let reason = suggestion.reason ?? "manual rule"
        directives.append(
          "Suggestion: Only change \"\(suggestion.alias)\" to \"\(suggestion.canonical)\" when the conversation matches (confidence: \(confidenceLabel), reason: \(reason))."
        )
      }
    }

    return directives
  }

  private func confidenceDescription(_ confidence: PersonalLexiconConfidence) -> String {
    switch confidence {
    case .high: return "high"
    case .medium: return "medium"
    case .low: return "low"
    }
  }

  private func maxConfidence(
    _ existing: PersonalLexiconConfidence?,
    _ candidate: PersonalLexiconConfidence
  ) -> PersonalLexiconConfidence {
    guard let existing else { return candidate }
    let order: [PersonalLexiconConfidence: Int] = [.low: 0, .medium: 1, .high: 2]
    if (order[candidate] ?? 0) >= (order[existing] ?? 0) {
      return candidate
    }
    return existing
  }
}
// @Implement This manager depends on the chat LLM protocol as a dependency and alongside app settings for any configuration. It can read the system prompt that should come with it and orchestrate sending the request off, receiving it, and sending it back to the caller.
// The default system message should be "The following message is a raw transcription. Improve the transcription by fixing grammar, punctuation, and formatting while preserving the original meaning. Only ever return the processed transcription, no additional text."
// The default model should use openrouter and "inception/mercury"
