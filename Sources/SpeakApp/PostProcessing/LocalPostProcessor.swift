import SpeakCore
import Foundation
import os.log

/// Runs post-processing on the local routes: Apple Intelligence, the built-in
/// rules cleaner and downloaded GGUF models. Remote routes never reach it.
@MainActor
struct LocalPostProcessor {
  /// Read per request so a temperature change applies to the next pass.
  let temperature: () -> Double
  let log: Logger

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

  /// Cleans `rawText` with the stock cleanup contract, or returns nil when
  /// `model` is a remote route that this type does not own.
  func process(
    model: String,
    rawText: String,
    systemPrompt: String
  ) async -> Result<PostProcessingOutcome, Error>? {
    switch PostProcessingModelRoute(model: model) {
    case .remote:
      return nil
    case .appleFoundation:
      return await processWithAppleFoundationModel(model: model, rawText: rawText, systemPrompt: systemPrompt)
    case .builtInRules:
      return .success(Self.rulesOutcome(rawText))
    case .downloaded:
      return await processWithDownloadedModel(model: model, rawText: rawText, systemPrompt: systemPrompt)
    }
  }

  /// Executes a user-supplied prompt pair on a local model, preserving both
  /// prompt values. The built-in rules (and, in App Store builds, downloaded
  /// models that cannot run) have no way to honour a prompt, so they throw.
  func polishWithCustomPrompt(
    model: String,
    systemPrompt: String,
    userMessage: String
  ) async throws -> String {
    switch PostProcessingModelRoute(model: model) {
    case .appleFoundation:
      return try await AppleFoundationModelPolisher.respond(
        systemPrompt: systemPrompt,
        userMessage: userMessage
      )
    case .builtInRules, .remote:
      throw PolishPromptError.customPromptUnsupported(model: model)
    case .downloaded:
      #if APP_STORE
      throw PolishPromptError.customPromptUnsupported(model: model)
      #else
      return try await LocalPostProcessingModelManager.shared.processWithExplicitPrompt(
        modelID: model,
        systemPrompt: systemPrompt,
        userMessage: userMessage,
        temperature: temperature()
      )
      #endif
    }
  }

  private static func rulesOutcome(_ rawText: String) -> PostProcessingOutcome {
    .init(
      original: rawText,
      processed: TranscriptPostProcessingPolicy.processLocally(rawText),
      response: nil,
      systemPrompt: "Local offline transcript cleanup",
      promptPayload: nil
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

  private func processWithDownloadedModel(
    model: String,
    rawText: String,
    systemPrompt: String
  ) async -> Result<PostProcessingOutcome, Error> {
    #if APP_STORE
    return .success(Self.rulesOutcome(rawText))
    #else
    do {
      let cleaned = try await LocalPostProcessingModelManager.shared.process(
        modelID: model,
        rawText: rawText,
        systemPrompt: systemPrompt,
        temperature: temperature()
      )
      let promptPayload = PostProcessingPromptPayload(
        modelIdentifier: model,
        customPrompt: nil,
        systemPrompt: LocalPostProcessingPrompt.systemPrompt(systemPrompt),
        userPrompt: LocalPostProcessingPrompt.userPrompt(rawText: rawText)
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
}
