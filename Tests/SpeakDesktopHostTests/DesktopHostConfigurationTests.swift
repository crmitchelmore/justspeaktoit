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

    func testWriteFailureLeavesAppliedAndImportedSettingsUnchanged() async throws {
        await controller.close()
        let effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let before = try await controller.configuration()
        try await controller.saveConfiguration(before.entries)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: settingsURL)
        effects.refusesWrites = true
        var entries = before.entries
        entries[0] = "de_DE"
        do { try await controller.saveConfiguration(entries); XCTFail("Failed save accepted") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let file = directory.appendingPathComponent("import.json")
        try Data(#"{"version":1,"preferences":{"preferredLocale":"fr_FR"}}"#.utf8).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Failed import accepted") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let after = try await controller.configuration()
        XCTAssertEqual(after.entries, before.entries)
        XCTAssertEqual(try Data(contentsOf: settingsURL), saved)
        XCTAssertEqual(effects.writes, 1)
    }

    func testOversizedAndUnsupportedImportsLeaveSettingsUnchanged() async throws {
        let before = try await controller.configuration()
        let file = directory.appendingPathComponent("invalid.json")
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Oversized import accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("1 MB")) }
        try Data(#"{"version":2,"preferences":{}}"#.utf8).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Unsupported version accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("version")) }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
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

    func testOversizedExportDoesNotReplaceExistingFile() async throws {
        let file = directory.appendingPathComponent("large.json")
        let preferences = try DesktopConfiguration(values: [
            "opaque": AnyCodable(.string(String(repeating: "a", count: 1_000_000)))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        var entries = try await controller.configuration().entries
        entries[1] = String(repeating: "a", count: 65_535)
        try await controller.saveConfiguration(entries)
        let original = Data("Existing export".utf8)
        try original.write(to: file)
        do { try await controller.exportConfiguration(path: file.path); XCTFail("Oversized export accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("1 MB")) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
