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
  private let log = Logger(subsystem: "com.github.speakapp", category: "PostProcessing")

  static let defaultPrompt =
    "The following message is a raw transcription. Improve the transcription by fixing grammar, punctuation, and formatting while preserving the original meaning. Only ever return the processed transcription, no additional text."

  init(client: ChatLLMClient, settings: AppSettings) {
    self.client = client
    self.settings = settings
  }

  private var effectiveSystemPrompt: String {
    let trimmed = settings.postProcessingSystemPrompt
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let basePrompt = trimmed.isEmpty ? Self.defaultPrompt : trimmed

    let language = settings.postProcessingOutputLanguage
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !language.isEmpty {
      return "Always output using \(language). \(basePrompt)"
    }

    return basePrompt
  }

  func process(rawText: String) async -> Result<PostProcessingOutcome, Error> {
    guard settings.postProcessingEnabled else {
      return .success(
        .init(
          original: rawText,
          processed: rawText,
          response: nil,
          systemPrompt: effectiveSystemPrompt
        )
      )
    }

    do {
      let systemPrompt = effectiveSystemPrompt
      let response = try await client.sendChat(
        systemPrompt: systemPrompt,
        messages: [ChatMessage(role: .user, content: rawText)],
        model: settings.postProcessingModel.isEmpty
          ? "inception/mercury"
          : settings
            .postProcessingModel,
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
}
// @Implement This manager depends on the chat LLM protocol as a dependency and alongside app settings for any configuration. It can read the system prompt that should come with it and orchestrate sending the request off, receiving it, and sending it back to the caller.
// The default system message should be "The following message is a raw transcription. Improve the transcription by fixing grammar, punctuation, and formatting while preserving the original meaning. Only ever return the processed transcription, no additional text."
// The default model should use openrouter and "inception/mercury"
