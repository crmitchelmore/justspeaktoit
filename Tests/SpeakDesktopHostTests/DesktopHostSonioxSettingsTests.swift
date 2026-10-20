import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostSonioxSettingsTests: XCTestCase {
    private var directory: URL!
    private var effects: SettingsWriteEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("soniox-settings-\(UUID())")
        effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testSoleModel_RestartTransferAndFavoritesKeepCanonicalVoiceAndRegionWithoutMirrors() async throws {
        let voice = try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first)
        var saved = DesktopVoiceOutputSettings(voice: voice)
        saved.sonioxRegion = "eu"
        saved.language = "fr_FR"
        saved.speed = 1.25
        saved.favoriteVoices = [voice.id, "soniox/deleted-clone", voice.id, "future/provider-voice"]
        await controller.saveVoiceOutput(saved)
        let selected = try await controller.currentVoiceSelection()
        XCTAssertEqual(selected.sonioxRegion, .europe)
        XCTAssertEqual(selected.language, "fr_FR")
        XCTAssertEqual(selected.voice, voice)
        let rawConfiguration = try await controller.configuration()
        XCTAssertTrue(SonioxVoicePreference.keys.isDisjoint(with: rawConfiguration.values.keys))
        let preferences = try await controller.configurationForNativeEditor()
        XCTAssertEqual(preferences.values[SonioxVoicePreference.regionKey], AnyCodable(.string("eu")))
        let export = directory.appendingPathComponent("soniox-export.json")
        try await controller.exportConfiguration(path: export.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: export))
        XCTAssertEqual(document.preferences.values[SonioxVoicePreference.regionKey], AnyCodable(.string("eu")))
        XCTAssertEqual(document.preferences.values[SonioxVoicePreference.languageKey], AnyCodable(.string("fr_FR")))
        XCTAssertEqual(try VoiceFavoritePreference.value(in: document.preferences.values), saved.favoriteVoices)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
        let picker = DesktopVoicePicker(voices: DesktopSpeechVoice.voices, favoriteIDs: restored.favoriteVoices ?? [])
        XCTAssertEqual(picker.favoriteIndices.map { picker.voices[$0].id }, [voice.id])
    }

    func testPartialImportsAndNativeEditor_UpdateOnlyPresentVoicePreferencesAndNeverSelectProvider() async throws {
        var saved = DesktopVoiceOutputSettings(voice: try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.last))
        saved.sonioxRegion = "eu"
        saved.favoriteVoices = ["soniox/deleted", "future/provider"]
        await controller.saveVoiceOutput(saved)
        try await importValues([
            "ttsSpeed": AnyCodable(.double(1.1)), "futureSetting": AnyCodable(.string("preserved"))
        ])
        let partial = await controller.voiceOutputSettings()
        XCTAssertEqual(partial.sonioxRegion, saved.sonioxRegion)
        XCTAssertEqual(partial.voiceID, saved.voiceID)
        XCTAssertEqual(partial.favoriteVoices, saved.favoriteVoices)
        var entries = try await controller.configurationForNativeEditor().entries
        let region = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == SonioxVoicePreference.regionKey })
        entries[region] = SonioxTTSRegion.japan.rawValue
        try await controller.saveConfiguration(entries)
        let changed = await controller.voiceOutputSettings()
        XCTAssertEqual(changed.sonioxRegion, "jp")
        XCTAssertEqual(changed.modelID, saved.modelID)
        XCTAssertEqual(changed.voiceID, saved.voiceID)
        XCTAssertEqual(changed.favoriteVoices, saved.favoriteVoices)
        let configuration = try await controller.configuration()
        XCTAssertTrue(SonioxVoicePreference.keys.isDisjoint(with: configuration.values.keys))
        XCTAssertEqual(configuration.values["futureSetting"], AnyCodable(.string("preserved")))
    }

    func testRecognizedRegionAliases_NormalizeOnlyTheEditorNotStoredOrExportedMaterial() async throws {
        for alias in ["", "europe", "japan", "global"] {
            var saved = DesktopVoiceOutputSettings()
            saved.sonioxRegion = alias
            await controller.saveVoiceOutput(saved)
            let editor = try await controller.configurationForNativeEditor()
            let expected = try XCTUnwrap(SonioxTTSRegion.recognized(from: alias))
            XCTAssertEqual(editor.values[SonioxVoicePreference.regionKey], AnyCodable(.string(expected.rawValue)))
            let current = await controller.voiceOutputSettings()
            XCTAssertEqual(current.sonioxRegion, alias)
            let raw = try DesktopVoiceOutputSettings.exportConfiguration(current, over: DesktopConfiguration())
            XCTAssertEqual(raw.values[SonioxVoicePreference.regionKey], AnyCodable(.string(alias)))
        }
    }

    func testProfileResolution_DoesNotReplaceIndependentSoleVoiceLanguageOrRegion() async throws {
        var saved = DesktopVoiceOutputSettings(
            voice: try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first))
        saved.sonioxRegion = "jp"
        saved.language = "fr_FR"
        await controller.saveVoiceOutput(saved)
        let executable = #"C:\Synthetic\Editor.exe"#
        await controller.saveProfiles([DictationProfile(
            name: "Synthetic profile", matchers: [.windowsExecutablePath(executable)], languageIdentifier: "de_DE")])
        let profile = await controller.resolvedProfile(executablePath: executable)
        XCTAssertEqual(profile.profileName, "Synthetic profile")
        XCTAssertEqual(profile.language, "de_DE")
        let voice = await controller.voiceOutputSettings()
        XCTAssertEqual(voice, saved)
        let selection = try await controller.currentVoiceSelection()
        XCTAssertEqual(selection.language, "fr_FR")
        XCTAssertEqual(selection.sonioxRegion, .japan)
    }

    func testUnknownRegionAndLanguage_StayStoredAndRefuseBeforeCredentialOrPlayback() async throws {
        var saved = DesktopVoiceOutputSettings(
            voice: try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first))
        saved.sonioxRegion = "future-region"
        await controller.saveVoiceOutput(saved)
        let preferences = try await controller.configurationForNativeEditor()
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == SonioxVoicePreference.regionKey })
        XCTAssertTrue(preferences.serializedChoices(for: field)?.contains("future-region\tUnsupported") == true)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Unsupported region/language accessed credentials") }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic unavailable region.")
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false))
        let operation = await controller.voiceGenerationTask
        XCTAssertNil(operation)
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertEqual(unchanged, saved)
        saved.sonioxRegion = "jp"
        saved.language = "future-unsupported-language"
        await controller.saveVoiceOutput(saved)
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false))
        let second = await controller.voiceGenerationTask
        XCTAssertNil(second)
        let stillSaved = await controller.voiceOutputSettings()
        XCTAssertEqual(stillSaved, saved)
    }

    func testInvalidImportAndFailedNativeWrite_AreAtomicForVoiceAndConfiguration() async throws {
        try await importValues([SonioxVoicePreference.regionKey: AnyCodable(.string("eu")),
                                "ttsFavoriteVoices": VoiceFavoritePreference.encoded(["soniox/Maya"])])
        let original = await controller.voiceOutputSettings()
        let path = directory.appendingPathComponent("settings.json")
        let raw = try Data(contentsOf: path)
        do {
            try await importValues([SonioxVoicePreference.regionKey: AnyCodable(.bool(true))])
            XCTFail("Invalid regional scalar imported")
        } catch { XCTAssertTrue(error is DesktopConfigurationError) }
        var entries = try await controller.configurationForNativeEditor().entries
        let region = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == SonioxVoicePreference.regionKey })
        entries[region] = "jp"
        effects.refusesWrites = true
        do { try await controller.saveConfiguration(entries); XCTFail("Failed write accepted") } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let retained = await controller.voiceOutputSettings()
        XCTAssertEqual(retained, original)
        XCTAssertEqual(try Data(contentsOf: path), raw)
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let path = directory.appendingPathComponent("synthetic-import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: values))).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }
}
