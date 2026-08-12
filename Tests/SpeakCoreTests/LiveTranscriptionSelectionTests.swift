import XCTest

@testable import SpeakCore

/// Behavioural coverage for the per-placement live model memory that keeps a
/// remote choice (Soniox) alive across local ↔ remote switches.
final class LiveTranscriptionSelectionTests: XCTestCase {

    private let soniox = "soniox/stt-rt-v5-streaming"
    private let deepgram = "deepgram/nova-3-streaming"

    private var appleModel: String { ModelCatalog.defaultOnDeviceLiveTranscriptionModel }

    // MARK: - Placement

    func testPlacementIsDerivedFromTheModelIdentifier() {
        XCTAssertEqual(LiveTranscriptionPlacement(modelID: appleModel), .onDevice)
        XCTAssertEqual(LiveTranscriptionPlacement(modelID: soniox), .remote)
    }

    // MARK: - Regression: Soniox must survive a mode switch

    func testReturningToRemoteRestoresSonioxRatherThanTheDeepgramDefault() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)

        let onDevice = selection.model(for: .onDevice, activeModel: soniox)
        XCTAssertEqual(onDevice, appleModel)

        let restored = selection.model(for: .remote, activeModel: onDevice)
        XCTAssertEqual(restored, soniox, "Switching back to remote must not fall back to Deepgram")
    }

    func testSwitchingToLocalRestoresThePreviousOnDeviceModel() {
        var selection = LiveTranscriptionSelection()
        selection.remember(appleModel)
        selection.remember(soniox)

        XCTAssertEqual(selection.model(for: .onDevice, activeModel: soniox), appleModel)
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), soniox)
    }

    func testChoosingOneModeDoesNotOverwriteTheOtherModesMemory() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        selection.remember(appleModel)

        XCTAssertEqual(selection.rememberedModel(for: .remote), soniox)
        XCTAssertEqual(selection.rememberedModel(for: .onDevice), appleModel)
    }

    func testActiveModelIsKeptWhenItAlreadyMatchesThePlacement() {
        var selection = LiveTranscriptionSelection()
        selection.remember(deepgram)

        XCTAssertEqual(selection.model(for: .remote, activeModel: soniox), soniox)
    }

    // MARK: - Defaults only when there is no valid choice

    func testDefaultAppliesOnlyWhenNothingValidIsRemembered() {
        let selection = LiveTranscriptionSelection()
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), deepgram)
    }

    func testUnknownRememberedModelFallsBackToTheDefault() {
        let selection = LiveTranscriptionSelection(remoteModel: "acme/not-a-real-model")
        XCTAssertNil(selection.rememberedModel(for: .remote))
        XCTAssertEqual(selection.model(for: .remote, activeModel: appleModel), deepgram)
    }

    func testEmptyOrMisplacedIdentifiersAreIgnored() {
        var selection = LiveTranscriptionSelection()
        selection.remember("")
        XCTAssertNil(selection.rememberedModel(for: .remote))

        let misplaced = LiveTranscriptionSelection(onDeviceModel: soniox, remoteModel: appleModel)
        XCTAssertNil(misplaced.rememberedModel(for: .onDevice))
        XCTAssertNil(misplaced.rememberedModel(for: .remote))
    }

    func testRememberIfMissingNeverReplacesAnExistingChoice() {
        var selection = LiveTranscriptionSelection(remoteModel: soniox)
        selection.rememberIfMissing(deepgram)
        XCTAssertEqual(selection.rememberedModel(for: .remote), soniox)
    }

    // MARK: - Platform-selectable filtering

    func testSelectableFilteringNeverReturnsAModelThePlatformCannotRun() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        let selectable: Set<String> = [deepgram, appleModel]

        XCTAssertEqual(
            selection.model(for: .remote, activeModel: appleModel, selectableModelIDs: selectable),
            deepgram
        )
    }

    func testSelectableFilteringKeepsARememberedModelThatIsStillAvailable() {
        var selection = LiveTranscriptionSelection()
        selection.remember(soniox)
        let selectable: Set<String> = [deepgram, soniox, appleModel]

        XCTAssertEqual(
            selection.model(for: .remote, activeModel: appleModel, selectableModelIDs: selectable),
            soniox
        )
    }

    // MARK: - Persistence (relaunch)

    func testSelectionSurvivesARelaunchThroughUserDefaults() throws {
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

    func testPersistenceClearsSlotsThatHaveNoRememberedValue() throws {
        let suiteName = "LiveTranscriptionSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("acme/not-a-real-model", forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel)
        LiveTranscriptionSelection().persist(to: defaults)

        XCTAssertNil(defaults.string(forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel))
    }
}
