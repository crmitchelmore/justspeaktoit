import SpeakCore
import XCTest

@testable import SpeakApp

/// End-to-end persistence behaviour for transcription selections: the settings
/// object is the source of truth, so mode switches and relaunches must never
/// replace a valid user choice with a default.
final class TranscriptionSelectionPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let soniox = "soniox/stt-rt-v5-streaming"
    private let deepgram = "deepgram/nova-3-streaming"
    private var appleModel: String { ModelCatalog.defaultOnDeviceLiveTranscriptionModel }

    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Reported regression

    @MainActor
    func testSoniox_survivesARoundTripThroughLocalMode() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.liveTranscriptionModel = soniox

        settings.selectTranscriptionLocation(.local)
        XCTAssertEqual(settings.transcriptionLocation, .local)

        settings.selectTranscriptionLocation(.remote)

        XCTAssertEqual(settings.liveTranscriptionModel, soniox)
        XCTAssertNotEqual(settings.liveTranscriptionModel, deepgram)
    }

    @MainActor
    func testSoniox_survivesRelaunchAfterAModeSwitch() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.liveTranscriptionModel = soniox
        settings.selectTranscriptionLocation(.local)
        settings.selectTranscriptionLocation(.remote)

        let relaunched = AppSettings(defaults: defaults)

        XCTAssertEqual(relaunched.liveTranscriptionModel, soniox)
        XCTAssertEqual(relaunched.transcriptionLocation, .remote)
        XCTAssertEqual(relaunched.remoteTranscriptionMode, .streaming)
    }

    @MainActor
    func testRemoteSelection_isRestoredEvenWhenTheAppIsQuitWhileInLocalMode() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.liveTranscriptionModel = soniox
        settings.selectTranscriptionLocation(.local)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.transcriptionLocation, .local)

        relaunched.selectTranscriptionLocation(.remote)
        XCTAssertEqual(relaunched.liveTranscriptionModel, soniox)
    }

    // MARK: - Independent local and remote selections

    @MainActor
    func testLocalSelection_isPreservedAcrossModeSwitchesAndRelaunch() {
        let settings = AppSettings(defaults: defaults)
        settings.selectTranscriptionLocation(.local)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionModel = "local/whisperkit/base"

        settings.selectTranscriptionLocation(.remote)
        settings.selectTranscriptionLocation(.local)

        XCTAssertEqual(settings.localTranscriptionSource, .downloaded)
        XCTAssertEqual(settings.transcriptionMode, .localModel)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.localTranscriptionSource, .downloaded)
        XCTAssertEqual(relaunched.localTranscriptionModel, "local/whisperkit/base")
    }

    @MainActor
    func testRemovingTheLastDownloadedModel_fallsBackToAppleSpeech() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)

        settings.repairDownloadedTranscriptionSelection(fallbackModelID: nil)

        XCTAssertEqual(settings.rememberedLocalTranscriptionSource, .apple)
        XCTAssertEqual(settings.localTranscriptionSource, .apple)
        XCTAssertTrue(settings.isAppleOnDeviceTranscriptionSelected)
    }

    @MainActor
    func testChangingTheOnDeviceModel_doesNotOverwriteTheRemoteSelection() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.liveTranscriptionModel = soniox

        settings.selectTranscriptionLocation(.local)
        settings.selectLocalTranscriptionSource(.apple)

        XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .remote), soniox)
        XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .onDevice), appleModel)
    }

    @MainActor
    func testRemoteBatchPreference_isRestoredWhenReturningFromLocal() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.batch)
        XCTAssertEqual(settings.transcriptionMode, .batchRemote)

        settings.selectTranscriptionLocation(.local)
        settings.selectTranscriptionLocation(.remote)

        XCTAssertEqual(settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(AppSettings(defaults: defaults).remoteTranscriptionMode, .batch)
    }

    // MARK: - Defaults only when nothing valid is stored

    @MainActor
    func testFirstRun_fallsBackToTheCatalogueDefaultForRemoteStreaming() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)

        XCTAssertEqual(settings.liveTranscriptionModel, deepgram)
    }

    @MainActor
    func testUpgrade_seedsTheMemoryFromTheExistingActiveModel() {
        defaults.set(soniox, forKey: AppSettings.DefaultsKey.liveTranscriptionModel.rawValue)

        let settings = AppSettings(defaults: defaults)
        settings.selectTranscriptionLocation(.local)
        settings.selectTranscriptionLocation(.remote)

        XCTAssertEqual(settings.liveTranscriptionModel, soniox)
    }

    @MainActor
    func testSessionProfileOverrides_doNotPersistTheModelMemory() {
        let settings = AppSettings(defaults: defaults)
        settings.liveTranscriptionModel = soniox

        settings.suppressesPersistence = true
        settings.liveTranscriptionModel = deepgram
        settings.suppressesPersistence = false

        XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .remote), soniox)
        XCTAssertEqual(
            defaults.string(forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel),
            soniox
        )
    }

    // MARK: - Launch-time auto-configuration

    @MainActor
    func testAnUntouchedInstall_hasNoExplicitModelChoice() {
        XCTAssertFalse(AppSettings(defaults: defaults).hasExplicitLiveTranscriptionModelChoice)
    }

    @MainActor
    func testChoosingAppleSpeech_countsAsAnExplicitChoice() {
        let settings = AppSettings(defaults: defaults)
        settings.selectTranscriptionLocation(.local)
        settings.selectLocalTranscriptionSource(.apple)

        XCTAssertTrue(settings.hasExplicitLiveTranscriptionModelChoice)
        XCTAssertTrue(AppSettings(defaults: defaults).hasExplicitLiveTranscriptionModelChoice)
    }
}

extension TranscriptionSelectionPersistenceTests {
    @MainActor
    func testSharedModelRemoval_withoutAnyReplacementFallsBackToAppleFromEitherLocalMode() {
        for mode in AppSettings.LocalTranscriptionMode.allCases {
            let settings = AppSettings(defaults: defaults)
            settings.selectLocalTranscriptionSource(.downloaded)
            settings.localTranscriptionMode = mode
            settings.localTranscriptionModel = "local/whisperkit/removed"
            settings.localStreamingModelSource = "removed-stream"

            settings.repairRemovedWhisperKitSelection(
                modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
                fallbackBatchModelID: nil, fallbackStreamingSourceID: nil
            )

            XCTAssertTrue(settings.isAppleOnDeviceTranscriptionSelected)
            XCTAssertEqual(settings.localStreamingModelSource, "")
            XCTAssertTrue(AppSettings(defaults: defaults).isAppleOnDeviceTranscriptionSelected)
        }
    }

    @MainActor
    func testRemovingSelectedStreamingModel_usesInstalledBatchReplacementAcrossRelaunch() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .streaming
        settings.localTranscriptionModel = "local/whisperkit/removed"
        settings.localStreamingModelSource = "local/whisperkit/streaming/removed"

        settings.repairDownloadedStreamingSelection(
            fallbackSourceID: nil, fallbackBatchModelID: "local/whisperkit/base"
        )

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.localTranscriptionModel, "local/whisperkit/base")
        XCTAssertEqual(relaunched.localTranscriptionMode, .batch)
        XCTAssertEqual(settings.localStreamingModelSource, "")
        XCTAssertEqual(defaults.string(forKey: AppSettings.DefaultsKey.localStreamingModelSource.rawValue), "")
        XCTAssertEqual(relaunched.transcriptionMode, .localModel)
    }

    @MainActor
    func testRemovingSelectedStreamingModel_withoutDownloadedReplacementUsesAppleSpeech() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .streaming

        settings.repairDownloadedStreamingSelection(fallbackSourceID: nil, fallbackBatchModelID: nil)

        XCTAssertTrue(settings.isAppleOnDeviceTranscriptionSelected)
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.rememberedLocalTranscriptionSource, .apple)
        XCTAssertTrue(relaunched.isAppleOnDeviceTranscriptionSelected)
    }

    @MainActor
    func testRemovingSelectedStreamingModel_prefersAnotherInstalledStreamingSource() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .streaming

        settings.repairDownloadedStreamingSelection(fallbackSourceID: "installed-source", fallbackBatchModelID: nil)

        XCTAssertEqual(settings.localStreamingModelSource, "installed-source")
        XCTAssertEqual(settings.localTranscriptionMode, .streaming)
        XCTAssertEqual(settings.transcriptionMode, .localModel)
    }

    @MainActor
    func testRemovingSelectedStreamingModel_doesNotSwitchAnActiveRemoteSessionToLocal() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.liveTranscriptionModel = soniox

        settings.repairDownloadedStreamingSelection(fallbackSourceID: nil, fallbackBatchModelID: nil)

        XCTAssertEqual(settings.transcriptionLocation, .remote)
        XCTAssertEqual(settings.liveTranscriptionModel, soniox)
        XCTAssertEqual(settings.rememberedLocalTranscriptionSource, .apple)
    }
}

extension TranscriptionSelectionPersistenceTests {
    @MainActor
    func testSharedModelRemoval_repairsBothIDsAndPreservesEachUsableLocalMode() {
        for mode in AppSettings.LocalTranscriptionMode.allCases {
            let settings = AppSettings(defaults: defaults)
            settings.selectLocalTranscriptionSource(.downloaded)
            settings.localTranscriptionMode = mode
            settings.localTranscriptionModel = "local/whisperkit/removed"
            settings.localStreamingModelSource = "removed-stream"

            settings.repairRemovedWhisperKitSelection(
                modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
                fallbackBatchModelID: "local/whisperkit/base", fallbackStreamingSourceID: "installed-stream"
            )

            let relaunched = AppSettings(defaults: defaults)
            XCTAssertEqual(relaunched.localTranscriptionModel, "local/whisperkit/base")
            XCTAssertEqual(settings.localStreamingModelSource, "installed-stream")
            XCTAssertEqual(defaults.string(forKey: "localStreamingModelSource"), "installed-stream")
            XCTAssertEqual(relaunched.localTranscriptionMode, mode)
            XCTAssertEqual(relaunched.transcriptionMode, .localModel)
        }
    }

    @MainActor
    func testSharedModelRemoval_preservesUnrelatedBatchChoiceWhenStreamingHasNoReplacement() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .batch
        settings.localTranscriptionModel = "local/whisperkit/chosen"
        settings.localStreamingModelSource = "removed-stream"

        settings.repairRemovedWhisperKitSelection(
            modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
            fallbackBatchModelID: "local/whisperkit/other", fallbackStreamingSourceID: nil
        )

        XCTAssertEqual(settings.localTranscriptionModel, "local/whisperkit/chosen")
        XCTAssertEqual(settings.localStreamingModelSource, "")
        XCTAssertEqual(settings.localTranscriptionMode, .batch)
        XCTAssertEqual(settings.transcriptionMode, .localModel)
    }

    @MainActor
    func testSharedModelRemoval_preservesUnrelatedStreamingChoiceWhenBatchHasNoReplacement() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .streaming
        settings.localTranscriptionModel = "local/whisperkit/removed"
        settings.localStreamingModelSource = "chosen-stream"

        settings.repairRemovedWhisperKitSelection(
            modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
            fallbackBatchModelID: nil, fallbackStreamingSourceID: "other-stream"
        )

        XCTAssertEqual(settings.localStreamingModelSource, "chosen-stream")
        XCTAssertEqual(settings.localTranscriptionMode, .streaming)
        XCTAssertEqual(settings.transcriptionMode, .localModel)
    }

    @MainActor
    func testSharedModelRemoval_preservesRemoteBatchWhileRepairingBothRememberedIDs() {
        let settings = AppSettings(defaults: defaults)
        settings.selectRemoteTranscriptionMode(.batch)
        let remoteModel = settings.batchTranscriptionModel
        settings.localTranscriptionModel = "local/whisperkit/removed"
        settings.localStreamingModelSource = "removed-stream"

        settings.repairRemovedWhisperKitSelection(
            modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
            fallbackBatchModelID: "local/whisperkit/base", fallbackStreamingSourceID: "installed-stream"
        )

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.transcriptionMode, .batchRemote)
        XCTAssertEqual(relaunched.batchTranscriptionModel, remoteModel)
        XCTAssertEqual(relaunched.localTranscriptionModel, "local/whisperkit/base")
        XCTAssertEqual(defaults.string(forKey: "localStreamingModelSource"), "installed-stream")
    }

    @MainActor
    func testSharedModelRemoval_usesRemainingStreamingSourceWhenSelectedBatchBecomesUnavailable() {
        let settings = AppSettings(defaults: defaults)
        settings.selectLocalTranscriptionSource(.downloaded)
        settings.localTranscriptionMode = .batch
        settings.localTranscriptionModel = "local/whisperkit/removed"
        settings.localStreamingModelSource = "removed-stream"

        settings.repairRemovedWhisperKitSelection(
            modelID: "local/whisperkit/removed", streamingSourceID: "removed-stream",
            fallbackBatchModelID: nil, fallbackStreamingSourceID: "installed-stream"
        )

        XCTAssertEqual(settings.localStreamingModelSource, "installed-stream")
        XCTAssertEqual(settings.localTranscriptionMode, .streaming)
        XCTAssertEqual(settings.transcriptionMode, .localModel)
    }
}
