#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// iOS persistence behaviour for transcription selections. `AppSettings` is the
/// source of truth, so a mode switch or relaunch must never replace a valid
/// user choice with a catalogue default.
@MainActor
final class TranscriptionSelectionPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let soniox = "soniox/stt-rt-v5-streaming"
    private let deepgram = "deepgram/nova-3-streaming"
    private var appleModel: String { ModelCatalog.defaultOnDeviceLiveTranscriptionModel }

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSelectionPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, loadsSecureStorage: false)
    }

    // MARK: - Reported regression

    func testSoniox_survivesARoundTripThroughLocalMode() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.selectedModel = soniox

        settings.selectTranscriptionLocation(.local)
        XCTAssertEqual(settings.transcriptionLocation, .local)
        XCTAssertEqual(settings.selectedModel, appleModel)

        settings.selectTranscriptionLocation(.remote)

        XCTAssertEqual(settings.selectedModel, soniox)
        XCTAssertNotEqual(settings.selectedModel, deepgram)
    }

    func testSoniox_survivesRelaunch() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.selectedModel = soniox
        settings.selectTranscriptionLocation(.local)

        let relaunched = makeSettings()
        XCTAssertEqual(relaunched.transcriptionLocation, .local)

        relaunched.selectTranscriptionLocation(.remote)
        XCTAssertEqual(relaunched.selectedModel, soniox)
    }

    func testSavingADeepgramKey_doesNotReplaceAChosenProvider() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.selectedModel = soniox

        settings.reconfigureDefaultProvider()

        XCTAssertEqual(settings.selectedModel, soniox)
    }

    // MARK: - Independent local and remote selections

    func testLocalAndRemoteSelections_areStoredIndependently() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)
        settings.selectedModel = soniox
        settings.selectTranscriptionLocation(.local)

        XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .remote), soniox)
        XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .onDevice), appleModel)
    }

    func testRemoteBatchPreference_isRestoredWhenReturningFromLocal() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.batch)
        XCTAssertEqual(settings.transcriptionMode, .batch)

        settings.selectTranscriptionLocation(.local)
        settings.selectTranscriptionLocation(.remote)

        XCTAssertEqual(settings.transcriptionMode, .batch)
        XCTAssertEqual(makeSettings().remoteTranscriptionMode, .batch)
    }

    func testBatchModelSelection_survivesRelaunch() throws {
        let settings = makeSettings()
        let batchModel = try XCTUnwrap(AppSettings.supportedBatchModels.last?.id)
        settings.batchTranscriptionModel = batchModel

        XCTAssertEqual(makeSettings().batchTranscriptionModel, batchModel)
    }

    // MARK: - Defaults only when nothing valid is stored

    func testFirstRun_usesTheCatalogueDefaultForRemoteStreaming() {
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)

        XCTAssertEqual(settings.selectedModel, deepgram)
    }

    func testOnlySelectableModels_areRestored() {
        defaults.set(
            "speechmatics/ursa-2-streaming",
            forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel
        )

        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.streaming)

        XCTAssertTrue(AppSettings.selectableLiveModelIDs.contains(settings.selectedModel))
    }

    // MARK: - Other user-configurable settings

    func testRepresentativeSettings_surviveRelaunch() {
        let settings = makeSettings()
        settings.autoStartRecording = true
        settings.liveActivitiesEnabled = false
        settings.visualDensity = .compact
        settings.hardwareTriggerDestination = .historyOnly
        settings.postProcessingEnabled = true
        settings.autoPostProcess = true
        settings.preferredLocaleIdentifier = "en-GB"

        let relaunched = makeSettings()
        XCTAssertTrue(relaunched.autoStartRecording)
        XCTAssertFalse(relaunched.liveActivitiesEnabled)
        XCTAssertEqual(relaunched.visualDensity, .compact)
        XCTAssertEqual(relaunched.hardwareTriggerDestination, .historyOnly)
        XCTAssertTrue(relaunched.postProcessingEnabled)
        XCTAssertTrue(relaunched.autoPostProcess)
        XCTAssertEqual(relaunched.preferredLocaleIdentifier, "en-GB")
    }
}
#endif
