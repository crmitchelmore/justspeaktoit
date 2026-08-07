import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

@MainActor
final class VoiceEditRewriterTests: XCTestCase {
  func testRewrite_usesVoiceEditPromptModelAndTemperature() async throws {
    let client = RecordingChatClient(responseText: "Shorter.")
    let settings = makeSettings()
    settings.postProcessingModel = "google/gemini-3.1-flash-lite"
    settings.postProcessingTemperature = 0.3
    let rewriter = VoiceEditRewriter(client: client, settings: settings)

    let result = try await rewriter.rewrite(
      selection: "A very long sentence.",
      instruction: "make this shorter"
    )

    XCTAssertEqual(result, "Shorter.")
    XCTAssertEqual(client.systemPrompts, [VoiceEditPolicy.systemPrompt])
    XCTAssertEqual(client.models, ["google/gemini-3.1-flash-lite"])
    XCTAssertEqual(client.temperatures, [0.3])
    let userMessage = try XCTUnwrap(client.userMessages.first)
    XCTAssertTrue(userMessage.contains("\"selectedText\":\"A very long sentence.\""))
    XCTAssertTrue(userMessage.contains("\"instruction\":\"make this shorter\""))
  }

  func testRewrite_normalizesTheModelResponse() async throws {
    let client = RecordingChatClient(responseText: "\n\"Tightened text.\"\n")
    let rewriter = VoiceEditRewriter(client: client, settings: makeSettings())

    let result = try await rewriter.rewrite(selection: "Loose text.", instruction: "tighten")

    XCTAssertEqual(result, "Tightened text.")
  }

  func testModel_prefersTheConfiguredCloudPostProcessingModel() {
    let settings = makeSettings()
    settings.postProcessingModel = "  qwen/qwen3.6-flash  "
    let rewriter = VoiceEditRewriter(client: RecordingChatClient(), settings: settings)

    XCTAssertEqual(rewriter.model, "qwen/qwen3.6-flash")
  }

  func testModel_fallsBackToCatalogDefaultWhenUnset() {
    let settings = makeSettings()
    settings.postProcessingModel = ""
    let rewriter = VoiceEditRewriter(client: RecordingChatClient(), settings: settings)

    XCTAssertEqual(rewriter.model, ModelCatalog.defaultPostProcessingModel)
  }

  func testModel_replacesLocalCleanupModelsWithCatalogDefault() {
    for localModel in [
      LocalPostProcessingModelManager.builtInRulesModelID,
      AppleLocalModels.foundationModelID,
      "local/post-processing/qwen3-0.6b-q4"
    ] {
      let settings = makeSettings()
      settings.postProcessingModel = localModel
      let rewriter = VoiceEditRewriter(client: RecordingChatClient(), settings: settings)

      XCTAssertEqual(
        rewriter.model,
        ModelCatalog.defaultPostProcessingModel,
        "Local model \(localModel) should defer to the catalog default for voice edits"
      )
    }
  }

  func testIsConfigured_isTrueForNonOpenRouterClients() async {
    let rewriter = VoiceEditRewriter(client: RecordingChatClient(), settings: makeSettings())

    let configured = await rewriter.isConfigured()

    XCTAssertTrue(configured)
  }

  // MARK: - Helpers

  private func makeSettings() -> AppSettings {
    let suiteName = "VoiceEditRewriterTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }
}

private final class RecordingChatClient: ChatLLMClient {
  private let responseText: String
  private(set) var systemPrompts: [String?] = []
  private(set) var userMessages: [String] = []
  private(set) var models: [String] = []
  private(set) var temperatures: [Double] = []

  init(responseText: String = "Rewritten") {
    self.responseText = responseText
  }

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    systemPrompts.append(systemPrompt)
    userMessages.append(contentsOf: messages.filter { $0.role == .user }.map(\.content))
    models.append(model)
    temperatures.append(temperature)
    return ChatResponse(
      messages: messages + [ChatMessage(role: .assistant, content: responseText)],
      finishReason: "stop",
      cost: nil,
      rawPayload: nil
    )
  }
}
