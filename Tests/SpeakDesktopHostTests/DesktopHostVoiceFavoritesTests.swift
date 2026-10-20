import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceFavoritesTests: XCTestCase {
    private var directory: URL!
    private var effects: SettingsWriteEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-favorites-\(UUID())")
        effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let path = directory.appendingPathComponent("transfer.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: values))).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }

    func testNativeActions_EditWithoutSelectingAndChooseExactFavorite() async throws {
        let voices = Array(DesktopSpeechVoice.voices.prefix(3))
        await controller.selectVoiceOutput(voices[0])
        let epoch = await controller.voiceCredentialEpoch
        await controller.handleVoicePicker(voiceID: voices[2].favoriteIdentifier, action: 1)
        var saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voiceID, voices[0].id)
        XCTAssertEqual(saved.favoriteVoices, [voices[2].favoriteIdentifier])
        let unchangedEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(epoch, unchangedEpoch)
        let picker = saved.favoritePicker(accountInventory: nil)
        let favorite = try XCTUnwrap(picker.favoriteRanks.firstIndex(of: 0))
        XCTAssertEqual(picker.identifiers[favorite], voices[2].favoriteIdentifier)
        await controller.handleVoicePicker(voiceID: picker.identifiers[favorite], action: 0)
        saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voiceID, voices[2].id)
        XCTAssertEqual(saved.modelID, voices[2].modelID)
        await controller.handleVoicePicker(voiceID: voices[2].favoriteIdentifier, action: 2)
        saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.favoriteVoices, [])
        XCTAssertEqual(saved.voiceID, voices[2].id)
    }

    func testTransfer_PartialImportRestartAndSoleModelAreLossless() async throws {
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first)
        let ids = ["future/provider/Voice", voice.favoriteIdentifier, "retired/id", voice.favoriteIdentifier]
        try await importValues([VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(ids)])
        try await importValues(["preferredLocale": AnyCodable(.string("en_GB"))])
        _ = await controller.saveVoiceGenerationOptions(.init(autoPlay: false, saveToRecordings: true))
        await controller.selectVoiceOutput(voice)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.favoriteVoices, ids)
        let config = try await controller.configuration()
        XCTAssertNil(config.values[VoiceFavoritePreference.key])
        let file = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: file.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        XCTAssertEqual(exported.preferences.values[VoiceFavoritePreference.key], VoiceFavoritePreference.encoded(ids))
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
        try await importValues([VoiceFavoritePreference.key: VoiceFavoritePreference.encoded([])])
        let cleared = await controller.voiceOutputSettings()
        XCTAssertEqual(cleared.favoriteVoices, [])
    }

    func testMalformedTransferAndWriteFailure_DoNotChangeSavedFavorites() async throws {
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first)
        await controller.handleVoicePicker(voiceID: voice.favoriteIdentifier, action: 1)
        let path = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: path)
        do {
            try await importValues([VoiceFavoritePreference.key: AnyCodable(.array([.int(1)]))])
            XCTFail("Malformed favorite list accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Favorite voices")) }
        XCTAssertEqual(try Data(contentsOf: path), before)
        effects.refusesWrites = true
        await controller.handleVoicePicker(voiceID: voice.favoriteIdentifier, action: 2)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.favoriteVoices, [voice.favoriteIdentifier])
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save Voice Output settings") == true)
    }

    func testUnavailableAndInvalidNativeActions_DoNotFallBackOrWrite() async throws {
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first)
        await controller.selectVoiceOutput(voice)
        let writes = effects.writes
        for action: Int32 in [0, 1, 2, 99] {
            await controller.handleVoicePicker(voiceID: "other/retired", action: action)
        }
        if case .deepgram(let deepgram) = voice {
            await controller.handleVoicePicker(voiceID: deepgram.id, action: 1)
            XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("no longer available") == true)
        }
        await controller.handleVoicePicker(voiceID: voice.favoriteIdentifier, action: 99)
        XCTAssertEqual(effects.writes, writes)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voiceID, voice.id)
        XCTAssertNil(saved.favoriteVoices)
        var unavailable = DesktopVoiceOutputSettings(modelID: "other/model", voiceID: "other/retired")
        unavailable.favoriteVoices = ["other/retired", voice.favoriteIdentifier]
        let picker = unavailable.favoritePicker(accountInventory: nil)
        XCTAssertEqual(picker.identifiers[picker.selected], "")
        XCTAssertEqual(picker.favoriteRanks[picker.selected], -1)
        XCTAssertEqual(picker.favoriteRanks.filter { $0 >= 0 }.count, 1)
    }

    func testLegacyMirror_IsAdoptedAtRestartWithoutOverridingSoleModel() async throws {
        await controller.close()
        let ids = ["future/id", "deepgram/retired"]
        var settings = DesktopHostController<FakePlatform>.Settings()
        settings.configuration = try DesktopConfiguration(values: [
            VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(ids), "future": AnyCodable(.int(8))
        ])
        let file = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: file)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let adopted = await controller.voiceOutputSettings()
        XCTAssertEqual(adopted.favoriteVoices, ids)
        let config = try await controller.configuration()
        XCTAssertNil(config.values[VoiceFavoritePreference.key])
        XCTAssertEqual(config.values["future"], AnyCodable(.int(8)))
        var live = DesktopVoiceOutputSettings()
        live.favoriteVoices = []
        settings.voiceOutput = live
        await controller.close()
        try JSONEncoder().encode(settings).write(to: file)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored.favoriteVoices, [])
    }

    func testQuickVoice_UsesRawFavoriteSlotsWithoutSkippingUnavailableOrDuplicateEntries() async throws {
        let voices = Array(DesktopSpeechVoice.voices.prefix(3))
        let favorites = ["future/unavailable", voices[2].favoriteIdentifier, voices[2].favoriteIdentifier]
        await controller.selectVoiceOutput(voices[0])
        try await importValues([VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(favorites)])
        let writes = effects.writes
        let before = await controller.voiceOutputSettings()
        await controller.selectQuickVoice(1)
        let refused = await controller.voiceOutputSettings()
        XCTAssertEqual(refused, before)
        XCTAssertEqual(effects.writes, writes)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Quick Voice 1 is unavailable") == true)
        for slot in [2, 3] {
            await controller.selectQuickVoice(slot)
            let selected = await controller.voiceOutputSettings()
            XCTAssertEqual(selected.voiceID, voices[2].id)
            XCTAssertEqual(selected.modelID, voices[2].modelID)
            XCTAssertEqual(selected.favoriteVoices, favorites)
        }
        let configuration = try await controller.configuration()
        XCTAssertNil(configuration.values[VoiceFavoritePreference.key])
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored.favoriteVoices, favorites)
        XCTAssertEqual(restored.voiceID, voices[2].id)
    }

    func testQuickVoice_PreservesTheCurrentModelWhenItsFavoriteVoiceIsExecutable() async throws {
        let voice = try XCTUnwrap(DesktopSpeechVoice.voices.first {
            $0.modelID == "openai/tts-1-hd" && $0.favoriteIdentifier == "openai/alloy"
        })
        await controller.selectVoiceOutput(voice)
        try await importValues([
            VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(["openai/nova"])
        ])
        let before = await controller.voiceOutputSettings()
        await controller.selectQuickVoice(1)
        let selected = await controller.voiceOutputSettings()
        XCTAssertEqual(selected.voiceID, "openai/nova")
        XCTAssertEqual(selected.modelID, voice.modelID)
        XCTAssertEqual(selected.quality, before.quality)
    }

    func testQuickVoice_CrossProviderSelectionDoesNotReadCredentials() async throws {
        try await importValues([
            VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(["openai/alloy"])
        ])
        FakeLog.shared.installKeyReadHook { name in
            XCTFail("Quick Voice selection must not read credentials: \(name)")
        }
        await controller.selectQuickVoice(1)
        let selected = await controller.voiceOutputSettings()
        XCTAssertEqual(selected.voiceID, "openai/alloy")
    }

    func testQuickVoice_MissingInvalidSlotsAndRefusedWritesPreserveSavedSelection() async throws {
        let voices = Array(DesktopSpeechVoice.voices.prefix(2))
        await controller.selectVoiceOutput(voices[0])
        let writes = effects.writes
        for slot in [-1, 0, 1, 3, 4] { await controller.selectQuickVoice(slot) }
        XCTAssertEqual(effects.writes, writes)
        try await importValues([
            VoiceFavoritePreference.key: VoiceFavoritePreference.encoded([voices[1].favoriteIdentifier])
        ])
        let path = directory.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: path)
        let before = await controller.voiceOutputSettings()
        effects.refusesWrites = true
        await controller.selectQuickVoice(1)
        let after = await controller.voiceOutputSettings()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save Voice Output settings") == true)
    }
}
