import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

@MainActor
final class PostProcessingOwnersTests: XCTestCase {
  private let rulesModel = "local/post-processing/rules"
  private let downloadedModel = "local/post-processing/qwen3-0.6b-q4"

  func testModelRoute_classifiesEachRouteAfterTrimming() {
    XCTAssertEqual(PostProcessingModelRoute(model: " \(AppleLocalModels.foundationModelID) "), .appleFoundation)
    XCTAssertEqual(PostProcessingModelRoute(model: " LOCAL/POST-PROCESSING/RULES\n"), .builtInRules)
    XCTAssertEqual(PostProcessingModelRoute(model: downloadedModel), .downloaded)
    XCTAssertEqual(PostProcessingModelRoute(model: "openai/gpt-4o-mini"), .remote)
    XCTAssertFalse(PostProcessingModelRoute(model: "openai/gpt-4o-mini").isLocal)
    XCTAssertTrue(PostProcessingModelRoute(model: rulesModel).isLocal)
  }

  func testOutputLanguage_mapsBritishAliasesAndTreatsBlankAsUnset() {
    XCTAssertEqual(PostProcessingPromptBuilder.outputLanguage(" ENGB "), "British English")
    XCTAssertEqual(PostProcessingPromptBuilder.outputLanguage("en_GB"), "British English")
    XCTAssertEqual(PostProcessingPromptBuilder.outputLanguage(" French "), "French")
    XCTAssertNil(PostProcessingPromptBuilder.outputLanguage("  \n"))
  }

  func testPromptBuilder_basePromptCarriesOverrideAndLanguage() {
    let settings = makeSettings()
    settings.postProcessingOutputLanguage = "ENGB"
    let builder = PostProcessingPromptBuilder(settings: settings, personalLexicon: makePersonalLexiconService())

    let prompt = builder.basePrompt(override: "Rewrite as bullet points.")

    XCTAssertTrue(prompt.contains("Rewrite as bullet points."), prompt)
    XCTAssertTrue(prompt.contains("British English"), prompt)
  }

  func testLocalProcessor_leavesRemoteModelsToTheRemoteOwner() async {
    let result = await makeLocal().process(model: "openai/gpt-4o-mini", rawText: "hello", systemPrompt: "p")
    XCTAssertNil(result)
  }

  func testLocalProcessor_rulesModelRunsOfflineCleanupWithoutPayload() async throws {
    let result = await makeLocal().process(model: rulesModel, rawText: "  hello   world ", systemPrompt: "p")

    let outcome = try XCTUnwrap(result).get()
    XCTAssertEqual(outcome.processed, TranscriptPostProcessingPolicy.processLocally("  hello   world "))
    XCTAssertEqual(outcome.systemPrompt, "Local offline transcript cleanup")
    XCTAssertNil(outcome.promptPayload)
  }

  func testLocalProcessor_rulesModelRejectsACustomPrompt() async {
    do {
      _ = try await makeLocal().polishWithCustomPrompt(model: rulesModel, systemPrompt: "s", userMessage: "u")
      XCTFail("The rules cleaner cannot follow a custom prompt")
    } catch let error as LocalPostProcessor.PolishPromptError {
      guard case .customPromptUnsupported(let model) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(model, rulesModel)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeLocal() -> LocalPostProcessor {
    LocalPostProcessor(temperature: { 0.2 }, log: SpeakLogger.logger(category: "PostProcessingOwnersTests"))
  }

  private func makeSettings() -> AppSettings {
    let suiteName = "PostProcessingOwnersTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }

  private func makePersonalLexiconService() -> PersonalLexiconService {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PostProcessingOwnersTests-\(UUID().uuidString)", isDirectory: true)
    return PersonalLexiconService(store: PersonalLexiconStore(baseDirectory: directory))
  }
}
