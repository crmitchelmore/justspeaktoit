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

  func process(
    rawText: String,
    context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?,
    onStreamingUpdate: ((String) -> Void)? = nil
  ) async -> Result<PostProcessingOutcome, Error> {
    await process(rawText: rawText, context: context, corrections: corrections,
                  onStreamingUpdate: onStreamingUpdate, onDiagnostic: nil)
  }

  func process(
    rawText: String,
    context: PersonalLexiconContext,
    corrections: PersonalLexiconHistorySummary?,
    onStreamingUpdate: ((String) -> Void)? = nil,
    onDiagnostic: ((RequestDiagnosticContext.PostProcessingObservation) -> Void)?
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
    let model = resolvedModel()

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

    return await Self.performRemoteProcess(
      client: client, rawText: rawText, promptPayload: promptPayload,
      settings: (streamingEnabled: { self.settings.postProcessingStreamingEnabled },
                 temperature: { self.settings.postProcessingTemperature }),
      delivery: .init(log: log, streamingUpdate: onStreamingUpdate, diagnostic: onDiagnostic)
    )
  }

  struct RemoteDelivery {
    let log: Logger
    let streamingUpdate: ((String) -> Void)?
    let diagnostic: ((RequestDiagnosticContext.PostProcessingObservation) -> Void)?
  }

  // swiftlint:disable:next function_body_length
  static func performRemoteProcess(
    client: ChatLLMClient, rawText: String, promptPayload: PostProcessingPromptPayload,
    settings: (streamingEnabled: () -> Bool, temperature: () -> Double),
    delivery: RemoteDelivery
  ) async -> Result<PostProcessingOutcome, Error> {
    // Actual remote delegate: lazy accessors preserve per-call reads without
    // constructing settings, secrets, local model managers or persistent state.
    let model = promptPayload.modelIdentifier
    let systemPrompt = promptPayload.systemPrompt
    let userMessage = promptPayload.userPrompt
    let log = delivery.log
    let onStreamingUpdate = delivery.streamingUpdate
    let onDiagnostic = delivery.diagnostic
    var fallbackObserved: Bool?
    // Try streaming if enabled and client supports it
    if settings.streamingEnabled(),
       let streamingClient = client as? StreamingChatLLMClient {
      do {
        var accumulated = ""
        let messages = [ChatMessage(role: .user, content: userMessage)]
        let requestedTemperature = settings.temperature()
        onDiagnostic?(Self.observation(model: model, streaming: true))
        let stream = streamingClient.sendChatStreaming(
          systemPrompt: systemPrompt,
          messages: messages,
          model: model,
          temperature: requestedTemperature
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
        fallbackObserved = true
        // Fall through to non-streaming
      }
    }

    // Non-streaming fallback
    do {
      let messages = [ChatMessage(role: .user, content: userMessage)]
      let requestedTemperature = settings.temperature()
      onDiagnostic?(Self.observation(model: model, streaming: false, fallbackObserved: fallbackObserved))
      let response = try await client.sendChat(
        systemPrompt: systemPrompt,
        messages: messages,
        model: model,
        temperature: requestedTemperature
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
      onDiagnostic?(Self.observation(
        model: model, streaming: false, fallbackObserved: fallbackObserved,
        failure: TranscriptionManager.batchFailure(error, stage: .postProcessing)
      ))
      return .failure(error)
    }
  }

  private static func observation(
    model: String, streaming: Bool, fallbackObserved: Bool? = nil,
    failure: RequestDiagnosticContext.Failure? = nil
  ) -> RequestDiagnosticContext.PostProcessingObservation {
    .init(handoff: .init(provenance: .observedHandoff, postProcessingModel: .project(model),
                         options: .init(streamingEnabled: streaming)),
          finalFailure: failure, fallbackObserved: fallbackObserved)
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

  /// A local model that cannot follow an arbitrary prompt was asked to run a
  /// custom Polish Text prompt. Silently performing stock cleanup instead
  /// would misrepresent the result, so the intent fails with this instead.
  enum PolishPromptError: LocalizedError {
    case customPromptUnsupported(model: String)

    var errorDescription: String? {
      switch self {
      case .customPromptUnsupported(let model):
        return "The configured post-processing model (\(model)) can't follow a custom prompt. "
          + "Choose an AI post-processing model in Settings, or leave the custom prompt empty."
      }
    }
  }

  /// Runs a one-off post-processing pass with an explicit prompt pair and
  /// returns the result, without touching session state. Used by the Polish
  /// Text App Intent so a custom Shortcuts prompt can replace the default
  /// cleanup contract (see `AutomationIntentSupport.polishRequest`) while the
  /// configured model — including Apple Foundation and downloaded local models
  /// that need no API key — and `postProcessingTemperature` still apply.
  ///
  /// `usesCustomPrompt` marks a prompt pair the user supplied themselves; the
  /// local execution paths then honour it verbatim instead of rebuilding the
  /// stock cleanup payload, and models that cannot follow a prompt (the
  /// built-in rules) fail clearly rather than silently performing cleanup.
  func polish(
    text: String,
    systemPrompt: String,
    userMessage: String,
    usesCustomPrompt: Bool = false
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
    let model = resolvedModel()

    if Self.isLocalPostProcessingModel(model) {
      if usesCustomPrompt {
        return try await polishLocallyWithCustomPrompt(
          model: model,
          systemPrompt: systemPrompt,
          userMessage: userMessage
        )
      }
      if let localResult = await processWithLocalModelIfNeeded(
        model: model,
        rawText: text,
        systemPrompt: systemPrompt
      ) {
        return try localResult.get().processed
      }
    }

    let response = try await client.sendChat(
      systemPrompt: systemPrompt,
      messages: [ChatMessage(role: .user, content: userMessage)],
      model: model,
      temperature: settings.postProcessingTemperature
    )
    return response.messages.last(where: { $0.role == .assistant })?.content ?? ""
  }

  /// Executes a user-supplied prompt pair on a local model, preserving both
  /// prompt values. The built-in rules (and, in App Store builds, downloaded
  /// models that cannot run) have no way to honour a prompt, so they throw.
  private func polishLocallyWithCustomPrompt(
    model: String,
    systemPrompt: String,
    userMessage: String
  ) async throws -> String {
    if Self.isAppleFoundationModel(model) {
      return try await AppleFoundationModelPolisher.respond(
        systemPrompt: systemPrompt,
        userMessage: userMessage
      )
    }
    guard !Self.isBuiltInLocalPostProcessingModel(model) else {
      throw PolishPromptError.customPromptUnsupported(model: model)
    }
    #if APP_STORE
    throw PolishPromptError.customPromptUnsupported(model: model)
    #else
    return try await LocalPostProcessingModelManager.shared.processWithExplicitPrompt(
      modelID: model,
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      temperature: settings.postProcessingTemperature
    )
    #endif
  }

  /// The system prompt a polish with no lexicon context would use: the user's
  /// configured base prompt (or active profile override) and output language.
  /// Shortcuts has no destination app or correction history, so the lexicon
  /// directives that `process` adds are deliberately omitted.
  func effectiveSystemPrompt() -> String {
    basePrompt()
  }

  /// The configured post-processing model, falling back to the default when
  /// the setting is empty. Single source of truth so the key check, the session
  /// path, and the automation path can never disagree about which model runs.
  private func resolvedModel() -> String {
    ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel)
  }

  func hasRequiredAPIKey() async -> Bool {
    let resolvedModel = resolvedModel()

    if Self.isLocalPostProcessingModel(resolvedModel) {
      return true
    }

    // Paid access wraps the OpenRouter client. When paid routing is actually
    // serving this request no personal key is needed; otherwise fall through to
    // the wrapped client so the "key required" warning stays truthful.
    if let proxy = client as? PaidAccessProxyClient {
      if await proxy.isPaidRoutingActive(configuredModel: resolvedModel) {
        return true
      }
      return await Self.hasOpenRouterAccess(proxy.fallback, model: resolvedModel)
    }

    guard let openRouterClient = client as? OpenRouterAPIClient else {
      return true
    }

    return await Self.hasOpenRouterAccess(openRouterClient, model: resolvedModel)
  }

  private static func hasOpenRouterAccess(
    _ client: any PaidAccessFallbackClient,
    model: String
  ) async -> Bool {
    let requiresRemote = await client.requiresRemoteAccess(for: model)
    if !requiresRemote {
      return true
    }
    return await client.hasStoredAPIKey()
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
    TranscriptPostProcessingPolicy.processLocally(text)
  }

  static func isEffectivelyEmptyTranscript(_ text: String) -> Bool {
    TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text)
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
    PersonalLexiconDirectives.build(rules: personalLexicon.rules, context: context, corrections: corrections)
  }

  // swiftlint:disable:next file_length
}
