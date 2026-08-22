import SpeakCore
import XCTest

@testable import SpeakApp

/// Profile overrides must execute exactly as configured for one session and
/// leave the user's own settings — including any they changed during the
/// session — intact afterwards (issue #690).
@MainActor
final class SessionProfileApplierTests: XCTestCase {
  private let bundleID = "com.example.editor"
  private let livePolishModel = "deepgram/nova-3-streaming"

  private var alternativePolishModel: String {
    ModelCatalog.postProcessing.first {
      $0.id != ModelCatalog.defaultPostProcessingModel && !$0.id.hasPrefix("local/")
    }?.id ?? ModelCatalog.defaultPostProcessingModel
  }

  // MARK: - Polish versus speed mode

  func testPolishProfile_runsEndOfSessionPolishEvenWhenTheUserUsesLivePolish() {
    let harness = makeHarness()
    harness.settings.transcriptionMode = .liveNative
    harness.settings.liveTranscriptionModel = livePolishModel
    harness.settings.speedMode = .livePolish
    XCTAssertFalse(harness.settings.postProcessingEnabled, "Live Polish disables end-of-session polish")

    let profile = DictationProfile(
      name: "Polished",
      matchers: [.bundleID(bundleID)],
      polishEnabled: true,
      polishModelID: alternativePolishModel
    )
    harness.begin(profile)

    XCTAssertEqual(harness.settings.speedMode, .instant, "Profile polish needs the instant speed mode")
    XCTAssertTrue(
      harness.settings.postProcessingEnabled,
      "The override must not be rejected by the speed-mode invariant"
    )
    XCTAssertEqual(harness.settings.postProcessingModel, alternativePolishModel)
    XCTAssertEqual(harness.applier.activeProfileName, "Polished")
    XCTAssertEqual(
      harness.persistedSettings.speedMode, .livePolish,
      "The temporary speed mode is session-only and never persisted"
    )
    XCTAssertFalse(harness.persistedSettings.postProcessingEnabled)

    harness.end()

    XCTAssertEqual(harness.settings.speedMode, .livePolish)
    XCTAssertFalse(harness.settings.postProcessingEnabled)
    XCTAssertEqual(harness.settings.postProcessingModel, ModelCatalog.defaultPostProcessingModel)
    XCTAssertNil(harness.applier.activeProfileName)
  }

  func testDisablingPolishProfile_restoresTheUsersEnabledPolish() {
    let harness = makeHarness()
    harness.settings.postProcessingEnabled = true

    harness.begin(DictationProfile(name: "Raw", matchers: [.bundleID(bundleID)], polishEnabled: false))
    XCTAssertFalse(harness.settings.postProcessingEnabled)

    harness.end()
    XCTAssertTrue(harness.settings.postProcessingEnabled)
  }

  // MARK: - Mid-session edits

  func testSettingsChangedDuringTheSession_surviveRestore() {
    let harness = makeHarness()
    harness.settings.postProcessingModel = ModelCatalog.defaultPostProcessingModel
    harness.settings.postProcessingIncludeContextTags = true
    let profile = DictationProfile(
      name: "Profile",
      matchers: [.bundleID(bundleID)],
      polishEnabled: true,
      polishModelID: alternativePolishModel,
      polishIncludeContextTags: false
    )
    harness.begin(profile)
    XCTAssertEqual(harness.settings.postProcessingModel, alternativePolishModel)

    // The user changes an overridden setting and an untouched one while recording.
    harness.settings.postProcessingModel = "local/post-processing/rules"
    harness.settings.postProcessingTemperature = 0.9

    harness.end()

    XCTAssertEqual(
      harness.settings.postProcessingModel, "local/post-processing/rules",
      "A value the user chose during the session is theirs, not the profile's to undo"
    )
    XCTAssertEqual(harness.persistedSettings.postProcessingModel, "local/post-processing/rules")
    XCTAssertTrue(harness.settings.postProcessingIncludeContextTags, "Untouched overrides are still restored")
    XCTAssertEqual(harness.settings.postProcessingTemperature, 0.9)
  }

  func testSpeedModeChangedDuringTheSession_isKept() {
    let harness = makeHarness()
    harness.settings.transcriptionMode = .liveNative
    harness.settings.liveTranscriptionModel = livePolishModel
    harness.settings.speedMode = .instant
    harness.settings.postProcessingEnabled = true

    harness.begin(DictationProfile(name: "Polished", matchers: [.bundleID(bundleID)], polishEnabled: true))
    harness.settings.speedMode = .livePolish

    harness.end()

    XCTAssertEqual(harness.settings.speedMode, .livePolish)
    XCTAssertFalse(harness.settings.postProcessingEnabled, "Live Polish, chosen mid-session, still excludes polish")
  }

  // MARK: - Transcription routing

  func testCustomStreamingModel_withExplicitRouting_isAppliedAsLive() {
    let harness = makeHarness()
    harness.settings.transcriptionMode = .batchRemote
    let originalLiveModel = harness.settings.liveTranscriptionModel
    let profile = DictationProfile(
      name: "Custom streaming",
      matchers: [.bundleID(bundleID)],
      transcriptionModelID: "deepgram/nova-4-custom-streaming",
      transcriptionRouting: .remoteStreaming
    )

    harness.begin(profile)

    XCTAssertEqual(harness.settings.transcriptionMode, .liveNative)
    XCTAssertEqual(harness.settings.liveTranscriptionModel, "deepgram/nova-4-custom-streaming")
    XCTAssertEqual(harness.persistedSettings.liveTranscriptionModel, originalLiveModel)

    harness.end()

    XCTAssertEqual(harness.settings.transcriptionMode, .batchRemote)
    XCTAssertEqual(harness.settings.liveTranscriptionModel, originalLiveModel)
  }

  func testLegacyProfileWithoutRouting_derivesFromTheIdentifier() {
    let harness = makeHarness()
    harness.begin(
      DictationProfile(name: "Legacy batch", matchers: [.bundleID(bundleID)], transcriptionModelID: "openai/whisper-1")
    )
    XCTAssertEqual(harness.settings.transcriptionMode, .batchRemote)
    XCTAssertEqual(harness.settings.batchTranscriptionModel, "openai/whisper-1")
    harness.end()

    harness.begin(
      DictationProfile(
        name: "Legacy local", matchers: [.bundleID(bundleID)], transcriptionModelID: "local/whisperkit/tiny"
      )
    )
    XCTAssertEqual(harness.settings.transcriptionMode, .localModel)
    XCTAssertEqual(harness.settings.localTranscriptionMode, .batch)
    XCTAssertEqual(harness.settings.localTranscriptionModel, "local/whisperkit/tiny")
    harness.end()
  }

  // MARK: - Polish model and rules cleanup

  func testUnsupportedPolishModel_isSkippedWhilePolishStillRuns() {
    let harness = makeHarness()
    harness.settings.postProcessingEnabled = false
    let profile = DictationProfile(
      name: "Odd model", matchers: [.bundleID(bundleID)], polishEnabled: true, polishModelID: "unknown/model"
    )

    harness.begin(profile)

    XCTAssertTrue(harness.settings.postProcessingEnabled)
    XCTAssertEqual(
      harness.settings.postProcessingModel, ModelCatalog.defaultPostProcessingModel,
      "A model the app cannot run is not applied; the user's model stays"
    )
  }

  func testRulesCleanupModel_doesNotApplyPromptLanguageOrLexiconOverrides() {
    let harness = makeHarness()
    harness.settings.postProcessingOutputLanguage = "English"
    harness.settings.postProcessingIncludeLexiconDirectives = true
    let profile = DictationProfile(
      name: "Rules",
      matchers: [.bundleID(bundleID)],
      polishEnabled: true,
      polishModelID: "local/post-processing/rules",
      polishPrompt: "Be terse.",
      polishOutputLanguage: "French",
      polishIncludeLexiconDirectives: false
    )

    harness.begin(profile)

    XCTAssertEqual(harness.settings.postProcessingModel, "local/post-processing/rules")
    XCTAssertNil(harness.postProcessing.sessionPromptOverride)
    XCTAssertEqual(harness.settings.postProcessingOutputLanguage, "English")
    XCTAssertTrue(harness.settings.postProcessingIncludeLexiconDirectives)
  }

  func testPromptOverride_isAppliedForLLMModelsAndClearedOnEnd() {
    let harness = makeHarness()
    let profile = DictationProfile(
      name: "Prompted",
      matchers: [.bundleID(bundleID)],
      polishEnabled: true,
      polishModelID: alternativePolishModel,
      polishPrompt: "Rewrite as bullet points.",
      polishOutputLanguage: "French"
    )

    harness.begin(profile)
    XCTAssertEqual(harness.postProcessing.sessionPromptOverride, "Rewrite as bullet points.")
    XCTAssertEqual(harness.settings.postProcessingOutputLanguage, "French")

    harness.end()
    XCTAssertNil(harness.postProcessing.sessionPromptOverride)
    XCTAssertNotEqual(harness.settings.postProcessingOutputLanguage, "French")
  }

  // MARK: - Lifecycle

  func testNoMatchingProfile_changesNothing() {
    let harness = makeHarness()
    let before = harness.snapshot()

    harness.applier.begin(
      settings: harness.settings,
      postProcessing: harness.postProcessing,
      profiles: [DictationProfile(name: "Other", matchers: [.bundleID("com.other.app")], polishEnabled: false)],
      frontmostBundleID: bundleID
    )

    XCTAssertNil(harness.applier.activeProfileName)
    XCTAssertEqual(harness.snapshot(), before)
  }

  func testBeginWhileActive_restoresThePreviousOverridesFirst_andEndIsIdempotent() {
    let harness = makeHarness()
    harness.settings.preferredLocaleIdentifier = "en_US"
    harness.begin(DictationProfile(name: "First", matchers: [.bundleID(bundleID)], languageIdentifier: "fr_FR"))
    XCTAssertEqual(harness.settings.preferredLocaleIdentifier, "fr_FR")

    harness.begin(DictationProfile(name: "Second", matchers: [.bundleID(bundleID)], polishEnabled: false))
    XCTAssertEqual(harness.settings.preferredLocaleIdentifier, "en_US", "The first profile's override was undone")
    XCTAssertEqual(harness.applier.activeProfileName, "Second")

    harness.end()
    harness.end()
    XCTAssertEqual(harness.settings.preferredLocaleIdentifier, "en_US")
    XCTAssertNil(harness.applier.activeProfileName)
  }

  // MARK: - Helpers

  private struct SettingsSnapshot: Equatable {
    let transcriptionMode: AppSettings.TranscriptionMode
    let liveModel: String
    let batchModel: String
    let speedMode: AppSettings.SpeedMode
    let polishEnabled: Bool
    let polishModel: String
    let locale: String
  }

  @MainActor
  private final class Harness {
    let defaults: UserDefaults
    let settings: AppSettings
    let postProcessing: PostProcessingManager
    let applier = SessionProfileApplier()
    private let bundleID: String

    init(bundleID: String) {
      let suiteName = "SessionProfileApplierTests-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defaults.removePersistentDomain(forName: suiteName)
      self.defaults = defaults
      self.settings = AppSettings(defaults: defaults)
      self.bundleID = bundleID
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(suiteName, isDirectory: true)
      self.postProcessing = PostProcessingManager(
        client: StubChatClient(),
        settings: settings,
        personalLexicon: PersonalLexiconService(store: PersonalLexiconStore(baseDirectory: directory))
      )
    }

    /// Settings as another launch would read them from the same defaults.
    var persistedSettings: AppSettings { AppSettings(defaults: defaults) }

    func begin(_ profile: DictationProfile) {
      applier.begin(
        settings: settings, postProcessing: postProcessing, profiles: [profile], frontmostBundleID: bundleID
      )
    }

    func end() {
      applier.end(settings: settings, postProcessing: postProcessing)
    }

    func snapshot() -> SettingsSnapshot {
      SettingsSnapshot(
        transcriptionMode: settings.transcriptionMode,
        liveModel: settings.liveTranscriptionModel,
        batchModel: settings.batchTranscriptionModel,
        speedMode: settings.speedMode,
        polishEnabled: settings.postProcessingEnabled,
        polishModel: settings.postProcessingModel,
        locale: settings.preferredLocaleIdentifier
      )
    }
  }

  private func makeHarness() -> Harness {
    Harness(bundleID: bundleID)
  }
}

private final class StubChatClient: ChatLLMClient {
  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    ChatResponse(
      messages: messages + [ChatMessage(role: .assistant, content: "stub")],
      finishReason: "stop",
      cost: nil,
      rawPayload: nil
    )
  }
}
