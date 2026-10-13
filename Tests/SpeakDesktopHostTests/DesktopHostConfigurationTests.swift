import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostConfigurationTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("configuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testSavePersistsPreferencesAndPreservesRootUnknownSettings() async throws {
        await controller.close()
        let values: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            "futureEngine": AnyCodable(.string("apple-only-engine"))
        ]
        let settingsURL = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(values).write(to: settingsURL)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        var entries = try await controller.configuration().entries
        entries[0] = "fr_FR"
        entries[4] = "0.6"
        entries[5] = "French"
        try await controller.saveConfiguration(entries)
        let disk = try JSONDecoder().decode([String: AnyCodable].self, from: Data(contentsOf: settingsURL))
        XCTAssertEqual(disk["futureEngine"], values["futureEngine"])
        let polish = await controller.postProcessingOptions()
        XCTAssertEqual(polish.temperature, 0.6)
        XCTAssertEqual(polish.outputLanguage, "French")
        XCTAssertEqual(polish.mode, .disabled)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = try await controller.configuration()
        XCTAssertEqual(restored.language, "fr_FR")
    }

    func testImportExportRetainsUnsupportedEntriesWithoutEnablingServices() async throws {
        let file = directory.appendingPathComponent("import.json")
        let document: [String: AnyCodable] = [
            "version": AnyCodable(.int(1)),
            "preferences": AnyCodable(.object([
                "preferredLocale": .string("de_DE"), "enableAutomationServer": .bool(true),
                "liveTranscriptionModel": .string("apple/local/speech"), "future": .array([.int(1)])
            ]))
        ]
        try JSONEncoder().encode(document).write(to: file)
        let model = await controller.settings.model
        try await controller.importConfiguration(path: file.path)
        let settings = await controller.settings
        XCTAssertEqual(settings.model, model)
        XCTAssertNil(settings.automationEnabled)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Preserved but not applied") == true)
        let exported = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: exported.path)
        let result = try JSONDecoder().decode([String: AnyCodable].self, from: Data(contentsOf: exported))
        XCTAssertEqual(result, document)
    }

    func testInvalidImportAndApplyLeavePreferencesUnchanged() async throws {
        let before = try await controller.configuration()
        let file = directory.appendingPathComponent("invalid.json")
        try Data(#"{"version":1,"preferences":{"holdThreshold":-1}}"#.utf8).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Invalid import accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Hold threshold")) }
        var entries = before.entries
        entries[4] = "2"
        do { try await controller.saveConfiguration(entries); XCTFail("Invalid temperature accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Temperature")) }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
    }

    func testHUDPreferencesGatePresentationAndLiveText() async throws {
        var entries = try await controller.configuration().entries
        entries[9] = "0"
        try await controller.saveConfiguration(entries)
        let id = UUID()
        await controller.beginHUD(id, .recording(profile: nil, liveText: "Synthetic speech"))
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "")
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .recording)
        await controller.finishHUD(id, .success("Done"))
        entries[8] = "0"
        try await controller.saveConfiguration(entries)
        await controller.beginHUD(UUID(), .recording(profile: nil, liveText: "Synthetic speech"))
        XCTAssertEqual(FakeLog.shared.huds.last, .hidden)
    }

    func testChangingPostProcessingDoesNotResetAdvancedPreferences() async throws {
        var entries = try await controller.configuration().entries
        entries[4] = "0.7"
        entries[5] = "German"
        try await controller.saveConfiguration(entries)
        await controller.savePostProcessing(enabled: false, modelIndex: 0, prompt: "Custom", key: "")
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved.temperature, 0.7)
        XCTAssertEqual(saved.outputLanguage, "German")
        XCTAssertEqual(saved.customPrompt, "Custom")
    }
}
