import SpeakCore
import XCTest

@testable import SpeakApp

/// What the profile editor stores and refuses, so a saved profile runs
/// exactly as displayed (issue #690).
@MainActor
final class ProfileEditorDraftTests: XCTestCase {
  func testStreamingChoice_storesExplicitStreamingRouting() {
    var draft = ProfileEditorDraft()
    draft.name = " Slack "
    draft.transcriptionChoice = .streaming
    draft.streamingModel = " deepgram/nova-4-custom-streaming "

    let profile = draft.profile(id: nil)

    XCTAssertEqual(profile.name, "Slack")
    XCTAssertEqual(profile.transcriptionModelID, "deepgram/nova-4-custom-streaming")
    XCTAssertEqual(profile.transcriptionRouting, .remoteStreaming)
    XCTAssertTrue(draft.canSave)
  }

  func testBatchChoice_storesBatchRouting_andDefaultStoresNone() {
    var draft = ProfileEditorDraft()
    draft.name = "Email"
    draft.transcriptionChoice = .batch
    draft.batchModel = "openai/whisper-1"
    XCTAssertEqual(draft.profile(id: nil).transcriptionRouting, .remoteBatch)

    draft.transcriptionChoice = .useDefault
    let profile = draft.profile(id: nil)
    XCTAssertNil(profile.transcriptionModelID)
    XCTAssertNil(profile.transcriptionRouting)
  }

  func testUnroutableCustomStreamingModel_blocksSaving() {
    var draft = ProfileEditorDraft()
    draft.name = "Odd"
    draft.transcriptionChoice = .streaming
    draft.streamingModel = "acme/fast-streaming"

    XCTAssertEqual(draft.issues, [.unknownStreamingProvider(modelID: "acme/fast-streaming")])
    XCTAssertFalse(draft.canSave)
  }

  func testEmptyName_blocksSaving() {
    var draft = ProfileEditorDraft()
    draft.name = "   "
    XCTAssertEqual(draft.issues, [.emptyName])
    XCTAssertFalse(draft.canSave)
  }

  func testRulesCleanup_dropsPromptLanguageAndLexiconControls() {
    var draft = ProfileEditorDraft()
    draft.name = "Rules"
    draft.polishChoice = .enabled
    draft.polishModel = LocalPostProcessingModelManager.builtInRulesModelID
    draft.useCustomPrompt = true
    draft.customPrompt = "Be terse."
    draft.outputLanguage = "French"
    draft.includeLexiconDirectives = true
    draft.includeContextTags = true

    XCTAssertTrue(draft.usesRulesCleanup)
    let profile = draft.profile(id: nil)
    XCTAssertEqual(profile.polishEnabled, true)
    XCTAssertEqual(profile.polishModelID, LocalPostProcessingModelManager.builtInRulesModelID)
    XCTAssertNil(profile.polishPrompt)
    XCTAssertNil(profile.polishOutputLanguage)
    XCTAssertNil(profile.polishIncludeLexiconDirectives)
    XCTAssertNil(profile.polishIncludeContextTags)
    XCTAssertTrue(draft.canSave)
  }

  func testLLMPolish_storesPromptLanguageAndLexiconControls() {
    var draft = ProfileEditorDraft()
    draft.name = "Polished"
    draft.polishChoice = .enabled
    draft.polishModel = ModelCatalog.defaultPostProcessingModel
    draft.useCustomPrompt = true
    draft.customPrompt = " Be terse. "
    draft.outputLanguage = "French"
    draft.includeLexiconDirectives = false
    draft.includeContextTags = true

    XCTAssertFalse(draft.usesRulesCleanup)
    let profile = draft.profile(id: nil)
    XCTAssertEqual(profile.polishPrompt, "Be terse.")
    XCTAssertEqual(profile.polishOutputLanguage, "French")
    XCTAssertEqual(profile.polishIncludeLexiconDirectives, false)
    XCTAssertEqual(profile.polishIncludeContextTags, true)
  }

  func testPolishNotOverridden_storesNoPolishFields() {
    for choice in [ProfilePolishChoice.useDefault, .disabled] {
      var draft = ProfileEditorDraft()
      draft.name = "Plain"
      draft.polishChoice = choice
      draft.polishModel = ModelCatalog.defaultPostProcessingModel
      draft.useCustomPrompt = true
      draft.customPrompt = "ignored"

      let profile = draft.profile(id: nil)
      XCTAssertEqual(profile.polishEnabled, choice == .disabled ? false : nil)
      XCTAssertNil(profile.polishModelID)
      XCTAssertNil(profile.polishPrompt)
    }
  }

  func testDraft_reopensACustomStreamingProfileAsStreaming() {
    let defaults = UserDefaults(suiteName: "ProfileEditorDraftTests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    let saved = DictationProfile(
      id: UUID(),
      name: "Custom",
      transcriptionModelID: "deepgram/nova-4-custom-streaming",
      transcriptionRouting: .remoteStreaming
    )

    let draft = ProfileEditorDraft(profile: saved, settings: settings)

    XCTAssertEqual(draft.transcriptionChoice, .streaming)
    XCTAssertEqual(draft.streamingModel, "deepgram/nova-4-custom-streaming")
    XCTAssertEqual(draft.profile(id: saved.id), saved)
  }

  func testDraft_keepsAProfilesIdentityOnSave() {
    let id = UUID()
    var draft = ProfileEditorDraft()
    draft.name = "Same"
    XCTAssertEqual(draft.profile(id: id).id, id)
  }
}
