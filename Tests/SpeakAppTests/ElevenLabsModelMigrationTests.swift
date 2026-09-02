import XCTest
import SpeakCore

@testable import SpeakApp

/// ElevenLabs retired `scribe_v1` (and its experimental variant) on 2026-07-09 and
/// deprecated `eleven_turbo_v2_5`. These tests pin the migrations that keep persisted
/// selections pointing at models ElevenLabs still serves.
final class ElevenLabsModelMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

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

    // MARK: - Catalogue Normalisation

    func testNormalizedBatchTranscriptionModel_migratesScribeV1ToScribeV2() {
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("elevenlabs/scribe_v1"),
            "elevenlabs/scribe_v2"
        )
    }

    func testNormalizedBatchTranscriptionModel_migratesScribeV1ExperimentalToScribeV2() {
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("elevenlabs/scribe_v1_experimental"),
            "elevenlabs/scribe_v2"
        )
    }

    func testNormalizedBatchTranscriptionModel_leavesScribeV2Untouched() {
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("elevenlabs/scribe_v2"),
            "elevenlabs/scribe_v2"
        )
    }

    // MARK: - Persisted Settings Migration

    @MainActor
    func testAppSettings_migratesPersistedScribeV1OnLoad() {
        defaults.set("elevenlabs/scribe_v1", forKey: "batchTranscriptionModel")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.batchTranscriptionModel, "elevenlabs/scribe_v2")
    }

    @MainActor
    func testAppSettings_migratesPersistedScribeV1ExperimentalOnLoad() {
        defaults.set("elevenlabs/scribe_v1_experimental", forKey: "batchTranscriptionModel")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.batchTranscriptionModel, "elevenlabs/scribe_v2")
    }

    // MARK: - Text-to-Speech Models

    func testTTSModels_currentCatalogueListsOnlySupportedModels() {
        let ids = ElevenLabsTTSModels.all.map(\.id)
        XCTAssertEqual(ids, ["eleven_v3", "eleven_multilingual_v2", "eleven_flash_v2_5"])
        XCTAssertFalse(ids.contains("eleven_turbo_v2_5"))
    }

    func testTTSModels_deprecatedTurboMapsToFlash() {
        XCTAssertEqual(ElevenLabsTTSModels.current("eleven_turbo_v2_5"), "eleven_flash_v2_5")
        XCTAssertEqual(ElevenLabsTTSModels.current("eleven_turbo_v2"), "eleven_flash_v2_5")
    }

    func testTTSModels_unknownIdentifierPassesThrough() {
        XCTAssertEqual(ElevenLabsTTSModels.current("eleven_custom_model"), "eleven_custom_model")
    }

    func testTTSModels_currentModelsAreUnchanged() {
        for model in ElevenLabsTTSModels.all {
            XCTAssertEqual(ElevenLabsTTSModels.current(model.id), model.id)
            XCTAssertFalse(model.displayName.isEmpty, "\(model.id) should have a display name")
        }
    }
}
