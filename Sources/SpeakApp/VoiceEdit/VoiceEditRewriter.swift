import Foundation
import SpeakCore
import os.log

/// Sends {selection, instruction} through the same LLM client, model, and temperature used for
/// transcript post-processing, but with the dedicated voice-edit prompt.
@MainActor
final class VoiceEditRewriter {
  private let client: ChatLLMClient
  private let settings: AppSettings
  private let log = Logger(subsystem: "com.github.speakapp", category: "VoiceEdit")

  init(client: ChatLLMClient, settings: AppSettings) {
    self.client = client
    self.settings = settings
  }

  /// The model used for voice edits: the configured post-processing model when it is a cloud
  /// chat model, otherwise the catalog default. Local cleanup models (rules engine, downloaded
  /// GGUF models, Apple Intelligence polish) are transcript-cleanup engines and cannot follow
  /// arbitrary editing instructions.
  var model: String {
    let configured = settings.postProcessingModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = configured.isEmpty ? ModelCatalog.defaultPostProcessingModel : configured
    if PostProcessingManager.isLocalPostProcessingModel(resolved) {
      return ModelCatalog.defaultPostProcessingModel
    }
    return resolved
  }

  /// Whether a usable model and credentials are in place for voice edits.
  func isConfigured() async -> Bool {
    guard let openRouterClient = client as? OpenRouterAPIClient else { return true }
    let requiresRemote = await openRouterClient.requiresRemoteAccess(for: model)
    guard requiresRemote else { return true }
    return await openRouterClient.hasStoredAPIKey()
  }

  func rewrite(selection: String, instruction: String) async throws -> String {
    let userMessage = VoiceEditPolicy.userMessage(selection: selection, instruction: instruction)
    let response = try await client.sendChat(
      systemPrompt: VoiceEditPolicy.systemPrompt,
      messages: [ChatMessage(role: .user, content: userMessage)],
      model: model,
      temperature: settings.postProcessingTemperature
    )
    let reply = response.messages.last(where: { $0.role == .assistant })?.content ?? ""
    log.info("Voice edit rewrite completed (\(reply.count, privacy: .public) characters)")
    return VoiceEditPolicy.normalizedRewrite(reply, original: selection, instruction: instruction)
  }
}
