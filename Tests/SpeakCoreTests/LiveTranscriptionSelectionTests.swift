import XCTest

@testable import SpeakCore

/// Behavioural coverage for the per-placement live model memory that keeps a
/// remote choice (Soniox) alive across local ↔ remote switches.
final class LiveTranscriptionSelectionTests: XCTestCase {

    private let soniox = "soniox/stt-rt-v5-streaming"
    private let deepgram = "deepgram/nova-3-streaming"

    private var appleModel: String { ModelCatalog.defaultOnDeviceLiveTranscriptionModel }

    // MARK: - Placement

    func testPlacement_isDerivedFromTheModelIdentifier() {
        XCTAssertEqual(LiveTranscriptionPlacement(modelID: appleModel), .onDevice)
        XCTAssertEqual(LiveTranscriptionPlacement(modelID: soniox), .remote)
    }

    // MARK: - Regression: Soniox must survive a mode switch

    func testReturningToRemote_restoresSonioxRatherThanTheDeepgramDefault() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)

        let onDevice = selection.model(for: .onDevice, activeModel: soniox)
        XCTAssertEqual(onDevice, appleModel)

        let restored = selection.model(for: .remote, activeModel: onDevice)
        XCTAssertEqual(restored, soniox, "Switching back to remote must not fall back to Deepgram")
    }

    func testSwitchingToLocal_restoresThePreviousOnDeviceModel() {
        var selection = LiveTranscriptionSelection()
        selection.remember(appleModel)
        selection.remember(soniox)

        XCTAssertEqual(selection.model(for: .onDevice, activeModel: soniox), appleModel)
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), soniox)
    }

    func testChoosingOneMode_doesNotOverwriteTheOtherModesMemory() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        selection.remember(appleModel)

        XCTAssertEqual(selection.rememberedModel(for: .remote), soniox)
        XCTAssertEqual(selection.rememberedModel(for: .onDevice), appleModel)
    }

    func testActiveModel_isKeptWhenItAlreadyMatchesThePlacement() {
        var selection = LiveTranscriptionSelection()
        selection.remember(deepgram)

        XCTAssertEqual(selection.model(for: .remote, activeModel: soniox), soniox)
    }

    // MARK: - Defaults only when there is no valid choice

    func testDefault_appliesOnlyWhenNothingValidIsRemembered() {
        let selection = LiveTranscriptionSelection()
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), deepgram)
    }

    func testNonLiveRememberedModel_fallsBackToTheDefault() {
        let selection = LiveTranscriptionSelection(remoteModel: "local/whisperkit/not-a-live-model")
        XCTAssertNil(selection.rememberedModel(for: .remote))
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), deepgram)
    }

    func testCustomRemoteModel_isRememberedAcrossPlacementSwitches() {
        let custom = "acme/realtime-v1"
        let selection = LiveTranscriptionSelection(remoteModel: custom)

        XCTAssertEqual(selection.rememberedModel(for: .remote), custom)
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), custom)
    }

    func testRetiredRememberedModel_isMigratedThroughTheSharedCatalogueRule() {
        let selection = LiveTranscriptionSelection(remoteModel: "assemblyai/universal-streaming")

        XCTAssertEqual(
            selection.rememberedModel(for: .remote),
            AssemblyAIModels.universal35ProStreamingID
        )
    }

    func testEmptyOrMisplacedIdentifiers_areIgnored() {
        var selection = LiveTranscriptionSelection()
        selection.remember("")
        XCTAssertNil(selection.rememberedModel(for: .remote))

        let misplaced = LiveTranscriptionSelection(onDeviceModel: soniox, remoteModel: appleModel)
        XCTAssertNil(misplaced.rememberedModel(for: .onDevice))
        XCTAssertNil(misplaced.rememberedModel(for: .remote))
    }

    func testRememberIfMissing_neverReplacesAnExistingChoice() {
        var selection = LiveTranscriptionSelection(remoteModel: soniox)
        selection.rememberIfMissing(deepgram)
        XCTAssertEqual(selection.rememberedModel(for: .remote), soniox)
    }

    // MARK: - Platform-selectable filtering

    func testSelectableFiltering_neverReturnsAModelThePlatformCannotRun() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        let selectable: Set<String> = [deepgram, appleModel]

        XCTAssertEqual(
            selection.model(for: .remote, activeModel: appleModel, selectableModelIDs: selectable),
            deepgram
        )
    }

    func testSelectableFiltering_keepsARememberedModelThatIsStillAvailable() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        let selectable: Set<String> = [deepgram, soniox, appleModel]

        XCTAssertEqual(
            selection.model(for: .remote, activeModel: appleModel, selectableModelIDs: selectable),
            soniox
        )
    }

    // MARK: - Persistence (relaunch)

    func testSelection_survivesARelaunchThroughUserDefaults() throws {
        let suiteName = "LiveTranscriptionSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        selection.remember(appleModel)
        selection.persist(to: defaults)

        let restored = LiveTranscriptionSelection(defaults: defaults)
        XCTAssertEqual(restored, selection)
        XCTAssertEqual(restored.model(for: .remote, activeModel: appleModel), soniox)
    }

    func testPersistence_clearsSlotsThatHaveNoRememberedValue() throws {
        let suiteName = "LiveTranscriptionSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            "local/whisperkit/not-a-live-model",
            forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel
        )
        LiveTranscriptionSelection().persist(to: defaults)

        XCTAssertNil(defaults.string(forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel))
    }
}
