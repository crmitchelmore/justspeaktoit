import XCTest

@testable import SpeakApp

/// The Output Language picker was moved into the location-independent part of the
/// Cleanup card because downloaded local models build their prompt from
/// `postProcessingOutputLanguage` exactly like remote models do (issue #852).
@MainActor
final class PostProcessingOutputLanguageTests: XCTestCase {
  private let localModelID = "local/post-processing/huggingface/unsloth-qwen3-0-6b-gguf/qwen3-0-6b-q4-k-m-gguf"
  private let remoteModelID = "openai/gpt-4o-mini"

  func testDownloadedLocalModel_isClassifiedAsLocalPostProcessing() {
    XCTAssertTrue(PostProcessingManager.isDownloadedLocalPostProcessingModel(localModelID))
    XCTAssertFalse(PostProcessingManager.isDownloadedLocalPostProcessingModel(remoteModelID))
  }

  func testLocalPromptPreview_usesTheConfiguredOutputLanguage() {
    let preview = SettingsView.systemPromptPreviewText(
      model: localModelID,
      outputLanguage: "French",
      lexiconRuleCount: 0,
      includeLexiconDirectives: false,
      includeContextTags: false
    )

    XCTAssertTrue(preview.contains("local model"), "expected the downloaded-local branch")
    XCTAssertTrue(preview.contains("French"), "local prompt must carry the output language")
  }

  func testLocalAndRemotePromptPreviews_bothTrackTheOutputLanguage() {
    for model in [localModelID, remoteModelID] {
      let english = SettingsView.systemPromptPreviewText(
        model: model,
        outputLanguage: "English",
        lexiconRuleCount: 0,
        includeLexiconDirectives: false,
        includeContextTags: false
      )
      let japanese = SettingsView.systemPromptPreviewText(
        model: model,
        outputLanguage: "Japanese",
        lexiconRuleCount: 0,
        includeLexiconDirectives: false,
        includeContextTags: false
      )

      XCTAssertNotEqual(english, japanese, "\(model) must react to the output language")
      XCTAssertTrue(japanese.contains("Japanese"), "\(model) must render the output language")
    }
  }

  func testLocalPromptPreview_normalisesTheBritishEnglishAlias() {
    let preview = SettingsView.systemPromptPreviewText(
      model: localModelID,
      outputLanguage: "ENGB",
      lexiconRuleCount: 0,
      includeLexiconDirectives: false,
      includeContextTags: false
    )

    XCTAssertTrue(preview.contains("British English"))
  }

  func testPickerOptions_areSharedByBothPostProcessingLocations() {
    let options = SettingsView.postProcessingOutputLanguages
    XCTAssertFalse(options.isEmpty)
    XCTAssertEqual(options.first, "English")
    XCTAssertEqual(Set(options).count, options.count, "no duplicate tags in the picker")

    // Every offered language has to survive the round trip into the prompt both
    // post-processing locations build.
    for language in options {
      for model in [localModelID, remoteModelID] {
        let preview = SettingsView.systemPromptPreviewText(
          model: model,
          outputLanguage: language,
          lexiconRuleCount: 0,
          includeLexiconDirectives: false,
          includeContextTags: false
        )
        XCTAssertTrue(preview.contains(language), "\(language) missing from \(model) prompt")
      }
    }
  }

  func testBuiltInRulesCleaner_hasNoPromptToLocalise() {
    let preview = SettingsView.systemPromptPreviewText(
      model: LocalPostProcessingModelManager.builtInRulesModelID,
      outputLanguage: "French",
      lexiconRuleCount: 0,
      includeLexiconDirectives: false,
      includeContextTags: false
    )

    XCTAssertTrue(preview.contains("does not send a prompt"))
  }
}
