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
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
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
