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

/// Session-facing post-processing entry point. It resolves the configured
/// model and prompt, then hands the request to `LocalPostProcessor` or
/// `RemotePostProcessor`; neither owner sees the other's route.
@MainActor
final class PostProcessingManager: ObservableObject {
  private let client: ChatLLMClient
  private let settings: AppSettings
  private let prompts: PostProcessingPromptBuilder
  private let local: LocalPostProcessor
  private let log: Logger

  static let defaultPrompt = TranscriptCleanupPolicy.baseSystemPrompt

  /// Session-scoped custom polish prompt from the active dictation profile.
  /// Set by `SessionProfileApplier` for the duration of a session; never persisted.
  var sessionPromptOverride: String?

  init(client: ChatLLMClient, settings: AppSettings, personalLexicon: PersonalLexiconService) {
    self.client = client
    self.settings = settings
    let log = SpeakLogger.logger(category: "PostProcessing")
    self.log = log
    self.prompts = PostProcessingPromptBuilder(settings: settings, personalLexicon: personalLexicon)
    self.local = LocalPostProcessor(temperature: { settings.postProcessingTemperature }, log: log)
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
      return .success(passthrough(rawText, processed: ""))
    }

    guard settings.postProcessingEnabled else {
      return .success(passthrough(rawText, processed: rawText))
    }

    let systemPrompt = prompts.systemPrompt(
      override: sessionPromptOverride, context: context, corrections: corrections
    )
    let model = resolvedModel()

    if let localResult = await local.process(model: model, rawText: rawText, systemPrompt: systemPrompt) {
      return localResult
    }

    let promptPayload = PostProcessingPromptPayload(
      modelIdentifier: model,
      customPrompt: nil,
      systemPrompt: systemPrompt,
      userPrompt: TranscriptCleanupPolicy.userMessage(transcript: rawText)
    )

    return await RemotePostProcessor.process(
      client: client, rawText: rawText, promptPayload: promptPayload,
      settings: (streamingEnabled: { self.settings.postProcessingStreamingEnabled },
                 temperature: { self.settings.postProcessingTemperature }),
      delivery: .init(log: log, streamingUpdate: onStreamingUpdate, diagnostic: onDiagnostic)
    )
  }

  private func passthrough(_ rawText: String, processed: String) -> PostProcessingOutcome {
    .init(
      original: rawText,
      processed: processed,
      response: nil,
      systemPrompt: prompts.basePrompt(override: sessionPromptOverride),
      promptPayload: nil
    )
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
        return try await local.polishWithCustomPrompt(
          model: model,
          systemPrompt: systemPrompt,
          userMessage: userMessage
        )
      }
      if let localResult = await local.process(model: model, rawText: text, systemPrompt: systemPrompt) {
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

  /// The system prompt a polish with no lexicon context would use: the user's
  /// configured base prompt (or active profile override) and output language.
  /// Shortcuts has no destination app or correction history, so the lexicon
  /// directives that `process` adds are deliberately omitted.
  func effectiveSystemPrompt() -> String {
    prompts.basePrompt(override: sessionPromptOverride)
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
      return await Self.hasRemoteCredentials(proxy.fallback, model: resolvedModel)
    }

    guard let openRouterClient = client as? OpenRouterAPIClient else {
      return true
    }

    return await Self.hasRemoteCredentials(openRouterClient, model: resolvedModel)
  }

  private static func hasRemoteCredentials(
    _ client: any PaidAccessFallbackClient,
    model: String
  ) async -> Bool {
    let requiresRemote = await client.requiresRemoteAccess(for: model)
    if !requiresRemote {
      return true
    }
    return await client.hasStoredAPIKey(forModel: model)
  }

  static func isLocalPostProcessingModel(_ model: String) -> Bool {
    PostProcessingModelRoute(model: model).isLocal
  }

  static func isAppleFoundationModel(_ model: String) -> Bool {
    PostProcessingModelRoute(model: model) == .appleFoundation
  }

  static func isBuiltInLocalPostProcessingModel(_ model: String) -> Bool {
    PostProcessingModelRoute(model: model) == .builtInRules
  }

  static func isDownloadedLocalPostProcessingModel(_ model: String) -> Bool {
    PostProcessingModelRoute(model: model) == .downloaded
  }

  static func isEffectivelyEmptyTranscript(_ text: String) -> Bool {
    TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text)
  }
}
