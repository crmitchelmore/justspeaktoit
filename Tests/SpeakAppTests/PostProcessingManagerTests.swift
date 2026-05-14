import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

@MainActor
final class PostProcessingManagerTests: XCTestCase {
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
    settings.postProcessingModel = "local/post-processing/qwen2.5-0.5b-instruct-q4"
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
    settings.postProcessingModel = "openai/gpt-4o-mini"
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

  func testLocalPostProcessingPromptMarksUserInstructionsAuthoritative() {
    let prompt = LocalPostProcessingModelManager.localUserPrompt(
      systemPrompt: "Put a full stop after each word.",
      rawText: "hello world"
    )

    XCTAssertTrue(prompt.contains("instructions below are authoritative"))
    XCTAssertTrue(prompt.contains("formatting-only instructions"))
    XCTAssertTrue(prompt.contains("Put a full stop after each word."))
    XCTAssertTrue(prompt.contains("<raw_transcript>\nhello world\n</raw_transcript>"))
    XCTAssertTrue(LocalPostProcessingModelManager.localSystemPrompt().contains("Follow the user's"))
  }

  func testCloudPostProcessingStillUsesLLMClient() async throws {
    let client = SpyChatClient(responseText: "Cleaned by cloud")
    let settings = makeSettings()
    settings.postProcessingModel = "openai/gpt-4o-mini"
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
    XCTAssertEqual(client.sendChatCallCount, 1)
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
