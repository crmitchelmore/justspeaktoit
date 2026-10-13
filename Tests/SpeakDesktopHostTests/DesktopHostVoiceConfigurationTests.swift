import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension FakePlatform {
    static var voiceConfigurationKeys: Set<String> { DesktopConfiguration.voiceGenerationTransferKeys }
    static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.exportConfiguration(voiceOutput, over: configuration)
    }
    static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.importConfiguration(from: configuration, into: &voiceOutput)
    }
}

final class DesktopHostVoiceConfigurationTests: XCTestCase {
    private var directory: URL!
    private var effects: SettingsWriteEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-config-\(UUID().uuidString)")
        effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let file = directory.appendingPathComponent("import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: values)
        )).write(to: file)
        try await controller.importConfiguration(path: file.path)
    }

    func testImportExport_UsesSoleVoiceAuthorityAndPreservesIDsAndForeignDirectory() async throws {
        let selected = try XCTUnwrap(DesktopVoiceOutputSettings.voices.last)
        await controller.selectVoiceOutput(selected)
        let foreign = AnyCodable(.string("/foreign/mac/recordings"))
        let writes = effects.writes
        try await importValues([
            "ttsAutoPlay": AnyCodable(.bool(false)), "ttsSaveToDirectory": AnyCodable(.bool(true)),
            "recordingsDirectory": foreign, "future": AnyCodable(.array([.int(7)]))
        ])
        XCTAssertEqual(effects.writes, writes + 1)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.modelID, selected.model.id)
        XCTAssertEqual(saved.voiceID, selected.id)
        XCTAssertEqual(saved.generationOptions, .init(autoPlay: false, saveToRecordings: true))
        let configuration = try await controller.configuration()
        XCTAssertTrue(configuration.values.keys.filter { DesktopConfiguration.voiceGenerationTransferKeys.contains($0) }
            .isEmpty)
        XCTAssertEqual(configuration.values["recordingsDirectory"], foreign)
        let export = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: export.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: export))
        XCTAssertEqual(document.preferences.values["ttsAutoPlay"], AnyCodable(.bool(false)))
        XCTAssertEqual(document.preferences.values["ttsSaveToDirectory"], AnyCodable(.bool(true)))
        XCTAssertEqual(document.preferences.values["recordingsDirectory"], foreign)
        XCTAssertEqual(document.preferences.values["future"], AnyCodable(.array([.int(7)])))
        let raw = try JSONDecoder().decode([String: AnyCodable].self,
                                         from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
        guard case .object(let voice)? = raw["voiceOutput"]?.storage else { return XCTFail("Voice model not saved.") }
        XCTAssertEqual(voice["ttsAutoPlay"], .bool(false))
        XCTAssertEqual(voice["ttsSaveToDirectory"], .bool(true))
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
    }

    func testPartialImportAndVoiceSelection_PreserveOtherFlagsAndDoNotDuplicateControls() async throws {
        let written = await controller.saveVoiceGenerationOptions(.init(autoPlay: false, saveToRecordings: false))
        XCTAssertTrue(written)
        try await importValues(["ttsSaveToDirectory": AnyCodable(.bool(true))])
        let selected = try XCTUnwrap(DesktopVoiceOutputSettings.voices.first)
        await controller.selectVoiceOutput(selected)
        var entries = try await controller.configuration().entries
        entries[0] = "fr_FR"
        try await controller.saveConfiguration(entries)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.generationOptions, .init(autoPlay: false, saveToRecordings: true))
        XCTAssertEqual(saved.voiceID, selected.id)
        XCTAssertEqual(entries.count, DesktopConfiguration.fields.count)
    }

    func testInvalidImportOrWriteFailure_IsAtomicAcrossVoiceAndDictation() async throws {
        try await importValues(["preferredLocale": AnyCodable(.string("en_GB")),
                                "ttsAutoPlay": AnyCodable(.bool(false))])
        let path = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: path)
        for refuseWrite in [false, true] {
            effects.refusesWrites = refuseWrite
            do {
                try await importValues([
                    "preferredLocale": AnyCodable(.string("fr_FR")),
                    "ttsAutoPlay": AnyCodable(.bool(true)),
                    "ttsSaveToDirectory": refuseWrite ? AnyCodable(.bool(true)) : AnyCodable(.string("true"))
                ])
                XCTFail("Invalid or failed import was accepted.")
            } catch {
                if refuseWrite {
                    XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
                } else {
                    XCTAssertTrue(error.localizedDescription.contains("Save generated speech"))
                }
            }
            XCTAssertEqual(try Data(contentsOf: path), before)
            let saved = await controller.voiceOutputSettings()
            XCTAssertEqual(saved.generationOptions, .init(autoPlay: false, saveToRecordings: false))
            let configuration = try await controller.configuration()
            XCTAssertEqual(configuration.language, "en_GB")
        }
    }

    func testHostWithoutVoiceBridge_PreservesButDoesNotApplyVoicePreferences() throws {
        let preferences = try DesktopConfiguration(values: ["ttsAutoPlay": AnyCodable(.bool(false))])
        var voice: FakeLocalPlatform.VoiceOutputSettings?
        let result = try FakeLocalPlatform.importVoiceConfiguration(from: preferences, into: &voice)
        XCTAssertNil(voice)
        XCTAssertEqual(result, preferences)
        XCTAssertTrue(FakeLocalPlatform.voiceConfigurationKeys.isEmpty)
    }

    func testExport_LiveModelWinsOverLegacyOpaqueMirrorWithoutMutatingIt() throws {
        let legacy = try DesktopConfiguration(values: [
            "ttsAutoPlay": AnyCodable(.bool(false)), "ttsSaveToDirectory": AnyCodable(.bool(true))
        ])
        var voice = DesktopVoiceOutputSettings()
        voice.autoPlay = true
        voice.saveToRecordings = false
        let exported = try DesktopVoiceOutputSettings.exportConfiguration(voice, over: legacy)
        XCTAssertEqual(exported.values["ttsAutoPlay"], AnyCodable(.bool(true)))
        XCTAssertEqual(exported.values["ttsSaveToDirectory"], AnyCodable(.bool(false)))
        XCTAssertEqual(legacy.values["ttsAutoPlay"], AnyCodable(.bool(false)))
    }
}
