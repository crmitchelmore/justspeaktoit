import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// A resolved profile becomes one immutable session snapshot: overrides apply
/// only where the host can run them, every gap is reported, and the defaults
/// the snapshot was taken from are never changed.
final class DesktopProfileSessionTests: XCTestCase {
    private let defaultModel = OpenAITranscriptionModels.gptTranscribeCatalogID
    private let defaultOptions = DesktopPostProcessing.Options(
        mode: .disabled, modelIdentifier: ModelCatalog.defaultPostProcessingModel, customPrompt: "Keep it short.",
        outputLanguage: nil, temperature: 0.3
    )
    private let capabilities = DesktopProfileCapabilities.shared

    private var batchModel: String {
        DesktopTranscription.batchModels.first { $0.id != defaultModel }?.id ?? defaultModel
    }

    private var liveModel: String { DesktopLiveTranscription.liveModels[0].id }

    private var alternativePolishModel: String {
        DesktopPostProcessing.remoteModels.first { $0.id != ModelCatalog.defaultPostProcessingModel }?.id
            ?? ModelCatalog.defaultPostProcessingModel
    }

    private func resolve(_ profile: DictationProfile?) -> DesktopProfileSession {
        DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: defaultModel, defaultPostProcessing: defaultOptions,
            capabilities: capabilities
        )
    }

    // MARK: - Inheritance

    func testNoProfileAndNilOverridesKeepEveryDefault() {
        let none = resolve(nil)
        XCTAssertNil(none.profileName)
        XCTAssertEqual(none.modelIdentifier, defaultModel)
        XCTAssertNil(none.language)
        XCTAssertEqual(none.postProcessing, defaultOptions)
        XCTAssertTrue(none.limitations.isEmpty)
        XCTAssertTrue(none.canRecord)

        let inherit = resolve(DictationProfile(name: "Inherit", matchers: [.windowsExecutablePath(#"C:\a\b.exe"#)]))
        XCTAssertEqual(inherit.profileName, "Inherit")
        XCTAssertEqual(inherit.modelIdentifier, defaultModel)
        XCTAssertEqual(inherit.postProcessing, defaultOptions)
        XCTAssertNil(inherit.language)
        XCTAssertTrue(inherit.limitations.isEmpty)
        XCTAssertNil(inherit.skippedPolishReason)
    }

    func testSharedCapabilitiesAreLiveProjectionsOfTheDesktopCatalogues() {
        XCTAssertEqual(capabilities.batchModels.map(\.id), DesktopTranscription.batchModels.map(\.id))
        XCTAssertEqual(capabilities.liveModels.map(\.id), DesktopLiveTranscription.liveModels.map(\.id))
        XCTAssertEqual(capabilities.polishModels.map(\.id), DesktopPostProcessing.remoteModels.map(\.id))
        XCTAssertFalse(capabilities.supportsPersonalLexicon)
        XCTAssertFalse(capabilities.supportsLiveLanguage)
        XCTAssertTrue(capabilities.canRun(transcriptionModel: " \(batchModel) ", routing: .remoteBatch))
        XCTAssertFalse(capabilities.canRun(transcriptionModel: batchModel, routing: .remoteStreaming))
        XCTAssertTrue(capabilities.canRun(transcriptionModel: liveModel, routing: .remoteStreaming))
        XCTAssertFalse(capabilities.canRun(transcriptionModel: liveModel, routing: .remoteBatch))
        XCTAssertFalse(capabilities.canRun(transcriptionModel: "local/whisperkit/tiny", routing: .localBatch))
        XCTAssertTrue(capabilities.canRun(polishModel: ModelCatalog.defaultPostProcessingModel))
        XCTAssertFalse(capabilities.canRun(polishModel: "local/post-processing/rules"))
    }

    // MARK: - Transcription

    func testExecutableBatchAndLiveOverridesBecomeTheSessionModel() {
        let batch = resolve(DictationProfile(
            name: "Batch", transcriptionModelID: batchModel, transcriptionRouting: .remoteBatch
        ))
        XCTAssertEqual(batch.modelIdentifier, batchModel)
        XCTAssertTrue(batch.canRecord)

        let live = resolve(DictationProfile(
            name: "Live", transcriptionModelID: liveModel, transcriptionRouting: .remoteStreaming
        ))
        XCTAssertEqual(live.modelIdentifier, liveModel)
        XCTAssertTrue(live.canRecord)

        let legacyLive = resolve(DictationProfile(name: "Legacy live", transcriptionModelID: liveModel))
        XCTAssertEqual(legacyLive.modelIdentifier, liveModel, "Routing derived from the identifier as on macOS")
    }

    func testUnavailableTranscriptionOverridesBlockRecordingInsteadOfSubstituting() {
        let local = resolve(DictationProfile(
            name: "Private", transcriptionModelID: "local/whisperkit/tiny", transcriptionRouting: .localBatch
        ))
        XCTAssertEqual(
            local.blockingLimitation,
            .transcriptionModelUnavailable(modelID: "local/whisperkit/tiny", routing: .localBatch)
        )
        XCTAssertFalse(local.canRecord)
        XCTAssertEqual(local.modelIdentifier, defaultModel, "The snapshot never names a model it will not run")
        XCTAssertTrue(local.blockingLimitation?.message.contains("WhisperKit Tiny") == true)

        let unknownBatch = resolve(DictationProfile(
            name: "Custom", transcriptionModelID: "acme/fast", transcriptionRouting: .remoteBatch
        ))
        XCTAssertFalse(unknownBatch.canRecord)

        let mismatched = resolve(DictationProfile(
            name: "Mismatch", transcriptionModelID: liveModel, transcriptionRouting: .remoteBatch
        ))
        XCTAssertFalse(mismatched.canRecord, "A live identifier stored under batch routing is not run as either")
    }

    // MARK: - Spoken language

    func testSpokenLanguageReachesBatchRequestsAndIsReportedForLiveModels() {
        let batch = resolve(DictationProfile(
            name: "French", transcriptionModelID: batchModel, languageIdentifier: "fr_FR",
            transcriptionRouting: .remoteBatch
        ))
        XCTAssertEqual(batch.language, "fr_FR")
        XCTAssertTrue(batch.limitations.isEmpty)

        let automatic = resolve(DictationProfile(name: "Auto", languageIdentifier: "automatic"))
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.limitations.isEmpty)

        let live = resolve(DictationProfile(
            name: "Live French", transcriptionModelID: liveModel, languageIdentifier: "fr_FR",
            transcriptionRouting: .remoteStreaming
        ))
        XCTAssertNil(live.language)
        XCTAssertEqual(live.limitations, [.languageUnavailableForLiveModel(languageIdentifier: "fr_FR")])
        XCTAssertTrue(live.canRecord)
    }

    // MARK: - Polish

    func testPolishEnabledDisabledAndKeepFollowTheProfile() {
        let enabled = resolve(DictationProfile(name: "On", polishEnabled: true))
        XCTAssertEqual(enabled.postProcessing.mode, .remote)
        XCTAssertEqual(enabled.postProcessing.modelIdentifier, defaultOptions.modelIdentifier)
        XCTAssertEqual(enabled.postProcessing.customPrompt, "Keep it short.", "A nil prompt keeps the user's prompt")
        XCTAssertEqual(enabled.postProcessing.temperature, 0.3)

        let disabled = resolve(DictationProfile(name: "Off", polishEnabled: false, polishModelID: alternativePolishModel))
        XCTAssertEqual(disabled.postProcessing.mode, .disabled)
        XCTAssertEqual(disabled.postProcessing.modelIdentifier, alternativePolishModel)

        var remoteDefaults = defaultOptions
        remoteDefaults.mode = .remote
        let kept = DesktopProfileSessionResolver.resolve(
            profile: DictationProfile(name: "Keep"), defaultModel: defaultModel,
            defaultPostProcessing: remoteDefaults, capabilities: capabilities
        )
        XCTAssertEqual(kept.postProcessing, remoteDefaults)
    }

    func testSupportedPolishModelPromptAndOutputLanguageApply() {
        let session = resolve(DictationProfile(
            name: "Polished",
            polishEnabled: true,
            polishModelID: alternativePolishModel,
            polishPrompt: " Rewrite as bullet points. ",
            polishOutputLanguage: "British English"
        ))
        XCTAssertEqual(session.postProcessing.mode, .remote)
        XCTAssertEqual(session.postProcessing.modelIdentifier, alternativePolishModel)
        XCTAssertEqual(session.postProcessing.customPrompt, "Rewrite as bullet points.")
        XCTAssertEqual(session.postProcessing.outputLanguage, "British English")
        XCTAssertTrue(session.limitations.isEmpty)
        XCTAssertNil(session.skippedPolishReason)
    }

    func testUnavailablePolishModelSkipsPolishRatherThanRunningAnotherModel() {
        let session = resolve(DictationProfile(
            name: "Offline", polishEnabled: true, polishModelID: "local/post-processing/rules",
            polishPrompt: "Be terse."
        ))
        XCTAssertEqual(session.postProcessing.mode, .disabled)
        XCTAssertEqual(session.postProcessing.modelIdentifier, defaultOptions.modelIdentifier)
        XCTAssertEqual(session.limitations, [.polishModelUnavailable(modelID: "local/post-processing/rules")])
        XCTAssertEqual(session.skippedPolishReason, session.limitations[0].message)
        XCTAssertTrue(session.canRecord)

        let disabledAnyway = resolve(DictationProfile(
            name: "Off", polishEnabled: false, polishModelID: "local/post-processing/rules"
        ))
        XCTAssertEqual(disabledAnyway.postProcessing.mode, .disabled)
        XCTAssertNil(disabledAnyway.skippedPolishReason, "Nothing was skipped: polish was disabled anyway")
        XCTAssertEqual(disabledAnyway.limitations, [.polishModelUnavailable(modelID: "local/post-processing/rules")])
    }

    func testLexiconRequestsAreReportedOnlyWhenPolishRuns() {
        let running = resolve(DictationProfile(
            name: "Lexicon", polishEnabled: true, polishIncludeLexiconDirectives: true, polishIncludeContextTags: true
        ))
        XCTAssertEqual(running.limitations, [.lexiconDirectivesUnavailable, .contextTagsUnavailable])
        XCTAssertTrue(running.canRecord)

        let off = resolve(DictationProfile(
            name: "Lexicon off", polishEnabled: false, polishIncludeLexiconDirectives: true
        ))
        XCTAssertTrue(off.limitations.isEmpty)

        let declined = resolve(DictationProfile(
            name: "Declined", polishEnabled: true, polishIncludeLexiconDirectives: false, polishIncludeContextTags: false
        ))
        XCTAssertTrue(declined.limitations.isEmpty, "Not asking for the lexicon is honoured trivially")
    }

    // MARK: - Snapshot semantics

    func testSnapshotIsIndependentOfTheDefaultsItWasTakenFrom() {
        var defaults = defaultOptions
        let profile = DictationProfile(name: "Snapshot", polishEnabled: true, polishPrompt: "Profile prompt")
        let session = DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: defaultModel, defaultPostProcessing: defaults, capabilities: capabilities
        )
        let copy = session

        defaults.mode = .remote
        defaults.customPrompt = "Changed while recording"
        defaults.modelIdentifier = alternativePolishModel

        XCTAssertEqual(session, copy)
        XCTAssertEqual(session.postProcessing.customPrompt, "Profile prompt")
        XCTAssertEqual(session.postProcessing.modelIdentifier, defaultOptions.modelIdentifier)
        XCTAssertEqual(defaults.mode, .remote, "The caller's defaults are its own; the session never wrote them")
        XCTAssertEqual(defaults.customPrompt, "Changed while recording")
    }

    func testDefaultsSessionCarriesAnExplicitLanguageForRetriesAndNoProfile() {
        let retry = DesktopProfileSession.defaults(
            modelIdentifier: batchModel, postProcessing: defaultOptions, language: "de_DE"
        )
        XCTAssertNil(retry.profileName)
        XCTAssertEqual(retry.modelIdentifier, batchModel)
        XCTAssertEqual(retry.language, "de_DE")
        XCTAssertTrue(retry.canRecord)
        XCTAssertTrue(retry.limitations.isEmpty)
    }

    func testEditorLimitationsDescribePreservedValuesWithoutDefaults() {
        let profile = DictationProfile(
            name: "Imported",
            matchers: [.bundleID("com.apple.Notes")],
            transcriptionModelID: "local/whisperkit/tiny",
            polishEnabled: true,
            polishModelID: "local/post-processing/rules",
            polishIncludeLexiconDirectives: true,
            languageIdentifier: "en_GB",
            transcriptionRouting: .localBatch
        )
        let limitations = DesktopProfileSessionResolver.limitations(of: profile, capabilities: capabilities)
        XCTAssertEqual(limitations, [
            .transcriptionModelUnavailable(modelID: "local/whisperkit/tiny", routing: .localBatch),
            .languageUnavailableForLiveModel(languageIdentifier: "en_GB"),
            .polishModelUnavailable(modelID: "local/post-processing/rules"),
            .lexiconDirectivesUnavailable
        ])
        for limitation in limitations {
            XCTAssertFalse(limitation.message.isEmpty)
        }
        let batchOnly = DictationProfile(
            name: "Batch", transcriptionModelID: batchModel, languageIdentifier: "en_GB",
            transcriptionRouting: .remoteBatch
        )
        XCTAssertTrue(
            DesktopProfileSessionResolver.limitations(of: batchOnly, capabilities: capabilities).isEmpty,
            "A batch override guarantees the language reaches the provider"
        )
    }
}
