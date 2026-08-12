import SpeakCore
import Foundation
import os.log

struct PostProcessingOutcome {
  let original: String
  let processed: String
  let response: ChatResponse?
  let systemPrompt: String
  let promptPayload: PostProcessingPromptPayload?
}

@MainActor
// swiftlint:disable:next type_body_length
final class PostProcessingManager: ObservableObject {
  private let client: ChatLLMClient
  private let settings: AppSettings
  private let personalLexicon: PersonalLexiconService
  private let log = SpeakLogger.logger(category: "PostProcessing")

  static let defaultPrompt = TranscriptCleanupPolicy.baseSystemPrompt

  /// Session-scoped custom polish prompt from the active dictation profile.
  /// Set by `SessionProfileApplier` for the duration of a session; never persisted.
  var sessionPromptOverride: String?

  init(client: ChatLLMClient, settings: AppSettings, personalLexicon: PersonalLexiconService) {
    self.client = client
    self.settings = settings
    self.personalLexicon = personalLexicon
  }

  // swiftlint:disable:next function_body_length
  func process(
    rawText: String,
    context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?,
    onStreamingUpdate: ((String) -> Void)? = nil
  ) async -> Result<PostProcessingOutcome, Error> {
    if Self.isEffectivelyEmptyTranscript(rawText) {
      return .success(
        .init(
          original: rawText,
          processed: "",
          response: nil,
          systemPrompt: basePrompt(),
          promptPayload: nil
        )
      )
    }

    guard settings.postProcessingEnabled else {
      return .success(
        .init(
          original: rawText,
          processed: rawText,
          response: nil,
          systemPrompt: basePrompt(),
          promptPayload: nil
        )
      )
    }

    let systemPrompt = effectiveSystemPrompt(for: context, corrections: corrections)
    let model = settings.postProcessingModel.isEmpty
      ? "inception/mercury"
      : settings.postProcessingModel

    if let localResult = await processWithLocalModelIfNeeded(
      model: model,
      rawText: rawText,
      systemPrompt: systemPrompt
    ) {
      return localResult
    }

    let userMessage = TranscriptCleanupPolicy.userMessage(transcript: rawText)
    let promptPayload = PostProcessingPromptPayload(
      modelIdentifier: model,
      customPrompt: nil,
      systemPrompt: systemPrompt,
      userPrompt: userMessage
    )

    // Try streaming if enabled and client supports it
    if settings.postProcessingStreamingEnabled,
       let streamingClient = client as? StreamingChatLLMClient {
      do {
        var accumulated = ""
        let stream = streamingClient.sendChatStreaming(
          systemPrompt: systemPrompt,
          messages: [ChatMessage(role: .user, content: userMessage)],
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
            systemPrompt: systemPrompt,
            promptPayload: promptPayload
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
        messages: [ChatMessage(role: .user, content: userMessage)],
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
          systemPrompt: systemPrompt,
          promptPayload: promptPayload
        )
      )
    } catch {
      log.error("Post-processing failed: \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  private func processWithLocalModelIfNeeded(
    model: String,
    rawText: String,
    systemPrompt: String
  ) async -> Result<PostProcessingOutcome, Error>? {
    guard Self.isLocalPostProcessingModel(model) else { return nil }

    if Self.isAppleFoundationModel(model) {
      return await processWithAppleFoundationModel(
        model: model,
        rawText: rawText,
        systemPrompt: systemPrompt
      )
    }

    if Self.isBuiltInLocalPostProcessingModel(model) {
      let cleaned = Self.processLocally(rawText)
      return .success(
        .init(
          original: rawText,
          processed: cleaned,
          response: nil,
          systemPrompt: "Local offline transcript cleanup",
          promptPayload: nil
        )
      )
    }

    return await processWithDownloadedLocalModel(
      model: model,
      rawText: rawText,
      systemPrompt: systemPrompt
    )
  }

  private func processWithAppleFoundationModel(
    model: String,
    rawText: String,
    systemPrompt: String
  ) async -> Result<PostProcessingOutcome, Error> {
    do {
      let cleaned = try await AppleFoundationModelPolisher.process(
        text: rawText,
        systemPrompt: systemPrompt
      )
      let promptPayload = PostProcessingPromptPayload(
        modelIdentifier: model,
        customPrompt: nil,
        systemPrompt: systemPrompt,
        userPrompt: TranscriptCleanupPolicy.userMessage(transcript: rawText)
      )
      return .success(
        .init(
          original: rawText,
          processed: cleaned.isEmpty ? rawText : cleaned,
          response: nil,
          systemPrompt: systemPrompt,
          promptPayload: promptPayload
        )
      )
    } catch {
      log.error("Apple Intelligence post-processing failed: \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
  }

  private func processWithDownloadedLocalModel(
    model: String,
    rawText: String,
    systemPrompt: String
  ) async -> Result<PostProcessingOutcome, Error> {
    #if APP_STORE
    let cleaned = Self.processLocally(rawText)
    return .success(
      .init(
        original: rawText,
        processed: cleaned,
        response: nil,
        systemPrompt: "Local offline transcript cleanup",
        promptPayload: nil
      )
    )
    #else
    do {
      let cleaned = try await LocalPostProcessingModelManager.shared.process(
        modelID: model,
        rawText: rawText,
        systemPrompt: systemPrompt,
        temperature: settings.postProcessingTemperature
      )
      let promptPayload = PostProcessingPromptPayload(
        modelIdentifier: model,
        customPrompt: nil,
        systemPrompt: LocalPostProcessingModelManager.localSystemPrompt(systemPrompt),
        userPrompt: LocalPostProcessingModelManager.localUserPrompt(systemPrompt: systemPrompt, rawText: rawText)
      )
      return .success(
        .init(
          original: rawText,
          processed: cleaned,
          response: nil,
          systemPrompt: systemPrompt,
          promptPayload: promptPayload
        )
      )
    } catch {
      log.error("Local post-processing failed: \(error.localizedDescription, privacy: .public)")
      return .failure(error)
    }
    #endif
  }

  func hasRequiredAPIKey() async -> Bool {
    let configuredModel = settings.postProcessingModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = configuredModel.isEmpty ? "inception/mercury" : configuredModel

    if Self.isLocalPostProcessingModel(resolvedModel) {
      return true
    }

    guard let openRouterClient = client as? OpenRouterAPIClient else {
      return true
    }

    let requiresRemote = await openRouterClient.requiresRemoteAccess(for: resolvedModel)
    if !requiresRemote {
      return true
    }

    return await openRouterClient.hasStoredAPIKey()
  }

  static func isLocalPostProcessingModel(_ model: String) -> Bool {
    isAppleFoundationModel(model)
      || isBuiltInLocalPostProcessingModel(model)
      || isDownloadedLocalPostProcessingModel(model)
  }

  static func isAppleFoundationModel(_ model: String) -> Bool {
    model.trimmingCharacters(in: .whitespacesAndNewlines) == AppleLocalModels.foundationModelID
  }

  static func isBuiltInLocalPostProcessingModel(_ model: String) -> Bool {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed == LocalPostProcessingModelManager.builtInRulesModelID
  }

  static func isDownloadedLocalPostProcessingModel(_ model: String) -> Bool {
    LocalPostProcessingModelManager.isDownloadedLocalModelID(
      model.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  static func processLocally(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }

    var cleaned = trimmed.replacingOccurrences(
      of: blankAudioMarkerPattern,
      with: " ",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"[ \t]+"#,
      with: " ",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"\s+([,.;:!?])"#,
      with: "$1",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"([,.;:!?])([^\s\]\)"'])"#,
      with: "$1 $2",
      options: .regularExpression
    )
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let first = cleaned.first else { return cleaned }
    let firstString = String(first)
    let capitalizedFirst = firstString.uppercased()
    if firstString != capitalizedFirst {
      cleaned.replaceSubrange(cleaned.startIndex...cleaned.startIndex, with: capitalizedFirst)
    }
    return cleaned
  }

  static func isEffectivelyEmptyTranscript(_ text: String) -> Bool {
    let withoutBlankAudioMarkers = text.replacingOccurrences(
      of: blankAudioMarkerPattern,
      with: " ",
      options: .regularExpression
    )
    return withoutBlankAudioMarkers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func basePrompt() -> String {
    TranscriptCleanupPolicy.systemPrompt(
      customBasePrompt: sessionPromptOverride,
      outputLanguage: normalizedOutputLanguage()
    )
  }

  private func effectiveSystemPrompt(
    for context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?
  ) -> String {
    let directives = lexiconDirectives(for: context, corrections: corrections)
    return TranscriptCleanupPolicy.systemPrompt(
      customBasePrompt: sessionPromptOverride,
      outputLanguage: normalizedOutputLanguage(),
      lexiconDirectives: settings.postProcessingIncludeLexiconDirectives ? directives : [],
      lexiconContextTags: settings.postProcessingIncludeContextTags ? Array(context.tags) : []
    )
  }

  private func normalizedOutputLanguage() -> String? {
    let language = settings.postProcessingOutputLanguage
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if language.uppercased() == "ENGB" || language.lowercased() == "en_gb" {
      return "British English"
    }
    return language.isEmpty ? nil : language
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

  private static let blankAudioMarkerPattern = #"(?i)\s*\[blank_audio\]\s*"#
  // swiftlint:disable:next file_length
}
