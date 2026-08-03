import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

@MainActor
final class PostProcessingManagerTests: XCTestCase {
  func testAppleFoundationModelIsTreatedAsLocal() {
    XCTAssertTrue(
      PostProcessingManager.isLocalPostProcessingModel(AppleLocalModels.foundationModelID)
    )
    XCTAssertTrue(
      PostProcessingManager.isAppleFoundationModel(AppleLocalModels.foundationModelID)
    )
  }

  func testLocalPostProcessingCleansTextWithoutCallingLLM() async throws {
    let client = SpyChatClient()
    let settings = makeSettings()
    settings.postProcessingModel = "local/post-processing/rules"
    let manager = PostProcessingManager(
      client: client,
      settings: settings,
      personalLexicon: makePersonalLexiconService()
    )

    let result = await manager.process(
      rawText: "  hello   world ,this is local [BLANK_AUDIO] cleanup  ",
      context: .empty,
      corrections: nil
    )

    let outcome = try result.get()
    XCTAssertEqual(outcome.processed, "Hello world, this is local cleanup")
    XCTAssertNil(outcome.response)
    XCTAssertEqual(client.sendChatCallCount, 0)
    let hasRequiredAPIKey = await manager.hasRequiredAPIKey()
    XCTAssertTrue(hasRequiredAPIKey)
  }

  func testDownloadedLocalPostProcessingDoesNotRequireOpenRouterKey() async throws {
    let client = SpyChatClient()
    let settings = makeSettings()
    settings.postProcessingModel = "local/post-processing/qwen3-0.6b-q4"
    let manager = PostProcessingManager(
      client: client,
      settings: settings,
      personalLexicon: makePersonalLexiconService()
    )

    XCTAssertTrue(PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel))
    XCTAssertTrue(PostProcessingManager.isDownloadedLocalPostProcessingModel(settings.postProcessingModel))
    let hasRequiredAPIKey = await manager.hasRequiredAPIKey()
    XCTAssertTrue(hasRequiredAPIKey)
  }

  func testEmptyTranscriptSkipsPostProcessingAndReturnsEmptyText() async throws {
    let client = SpyChatClient(responseText: "This is a raw transcript.")
    let settings = makeSettings()
    settings.postProcessingModel = ModelCatalog.defaultPostProcessingModel
    let manager = PostProcessingManager(
      client: client,
      settings: settings,
      personalLexicon: makePersonalLexiconService()
    )

    for rawText in ["", "   \n\t  ", "[BLANK_AUDIO]", "  [blank_audio]  "] {
      let result = await manager.process(
        rawText: rawText,
        context: .empty,
        corrections: nil
      )

      let outcome = try result.get()
      XCTAssertEqual(outcome.original, rawText)
      XCTAssertEqual(outcome.processed, "")
      XCTAssertNil(outcome.response)
    }
    XCTAssertEqual(client.sendChatCallCount, 0)
  }

  func testLocalPostProcessingUsesSharedPolicyAndJSONTranscriptPayload() {
    let systemPrompt = LocalPostProcessingModelManager.localSystemPrompt(
      TranscriptCleanupPolicy.systemPrompt()
    )
    let userPrompt = LocalPostProcessingModelManager.localUserPrompt(
      systemPrompt: "Put a full stop after each word.",
      rawText: "hello world"
    )

    XCTAssertTrue(systemPrompt.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
    XCTAssertTrue(systemPrompt.contains("never enter thinking mode"))
    XCTAssertFalse(userPrompt.contains("Put a full stop after each word."))
    XCTAssertTrue(userPrompt.contains("\"transcript\":\"hello world\""))
    XCTAssertFalse(userPrompt.contains("<raw_transcript>"))
  }

  func testLocalPostProcessingSanitizesThinkingTags() {
    let output = """
    <think>
    </think>

    Is it able to do anything?
    """

    XCTAssertEqual(
      LocalPostProcessingModelManager.sanitizedModelOutput(output),
      "Is it able to do anything?"
    )
    XCTAssertEqual(
      LocalPostProcessingModelManager.sanitizedModelOutput("<think>reasoning</think>\nHello."),
      "Hello."
    )
  }

  func testCloudPostProcessingStillUsesLLMClient() async throws {
    let client = SpyChatClient(responseText: "Cleaned by cloud")
    let settings = makeSettings()
    settings.postProcessingModel = ModelCatalog.defaultPostProcessingModel
    let manager = PostProcessingManager(
      client: client,
      settings: settings,
      personalLexicon: makePersonalLexiconService()
    )

    let result = await manager.process(
      rawText: "hello world",
      context: .empty,
      corrections: nil
    )

    let outcome = try result.get()
    XCTAssertEqual(outcome.processed, "Cleaned by cloud")
    XCTAssertNotNil(outcome.response)
    let promptPayload = try XCTUnwrap(outcome.promptPayload)
    XCTAssertEqual(promptPayload.modelIdentifier, ModelCatalog.defaultPostProcessingModel)
    XCTAssertNil(promptPayload.customPrompt)
    XCTAssertTrue(promptPayload.systemPrompt.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
    XCTAssertTrue(promptPayload.systemPrompt.contains("Output language context: use English"))
    XCTAssertTrue(promptPayload.userPrompt.contains("\"transcript\":\"hello world\""))
    XCTAssertFalse(promptPayload.userPrompt.contains("<raw_transcript>"))
    XCTAssertEqual(client.sendChatCallCount, 1)
  }

  func testHistoryPromptPayloadUsesGeneratedLanguageInstruction() async throws {
    let client = SpyChatClient(responseText: "Cleaned by cloud")
    let settings = makeSettings()
    settings.postProcessingModel = ModelCatalog.defaultPostProcessingModel
    settings.postProcessingOutputLanguage = "ENGB"
    let manager = PostProcessingManager(
      client: client,
      settings: settings,
      personalLexicon: makePersonalLexiconService()
    )

    let result = await manager.process(
      rawText: "hello world",
      context: .empty,
      corrections: nil
    )

    let outcome = try result.get()
    let promptPayload = try XCTUnwrap(outcome.promptPayload)
    XCTAssertNil(promptPayload.customPrompt)
    XCTAssertTrue(
      promptPayload.systemPrompt.contains("Output language context: use British English")
    )
    XCTAssertTrue(promptPayload.systemPrompt.hasSuffix("Return only the cleaned transcript text."))
  }

  func testMacDefaultPrompt_IsTheSharedCleanupPolicy() {
    XCTAssertEqual(
      PostProcessingManager.defaultPrompt,
      TranscriptCleanupPolicy.baseSystemPrompt
    )
  }

  private func makeSettings() -> AppSettings {
    let suiteName = "PostProcessingManagerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(defaults: defaults)
    settings.postProcessingEnabled = true
    settings.postProcessingStreamingEnabled = false
    return settings
  }

  private func makePersonalLexiconService() -> PersonalLexiconService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PostProcessingManagerTests-\(UUID().uuidString)", isDirectory: true)
    let store = PersonalLexiconStore(baseDirectory: directory)
    return PersonalLexiconService(store: store)
  }

}

private final class SpyChatClient: ChatLLMClient {
  private let responseText: String
  private(set) var sendChatCallCount = 0

  init(responseText: String = "Cleaned by LLM") {
    self.responseText = responseText
  }

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    sendChatCallCount += 1
    return ChatResponse(
      messages: messages + [ChatMessage(role: .assistant, content: responseText)],
      finishReason: "stop",
      cost: nil,
      rawPayload: nil
    )
  }
}
