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

    private func index(_ key: ApplicationPreferenceKey) throws -> Int {
        try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key.rawValue })
    }

    func testSidebarHints_SaveRestartExportImportAndFailedWrite() async throws {
        let key = ApplicationPreferenceKey.showSidebarShortcutHints
        var entries = try await controller.configuration().entries
        entries[try index(key)] = "0"
        try await controller.saveConfiguration(entries)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = try await controller.configuration()
        XCTAssertFalse(restored.enabled(key.rawValue))
        let file = directory.appendingPathComponent("sidebar.json")
        try await controller.exportConfiguration(path: file.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        XCTAssertEqual(document.preferences.values[key.rawValue], AnyCodable(.bool(false)))
        entries = restored.entries
        entries[try index(key)] = "1"
        try await controller.saveConfiguration(entries)
        try await controller.importConfiguration(path: file.path)
        let imported = try await controller.configuration()
        XCTAssertFalse(imported.enabled(key.rawValue))
        await controller.close()
        let effects = SettingsWriteEffects()
        effects.refusesWrites = true
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        do { try await controller.saveConfiguration(entries); XCTFail("Failed write accepted") } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let unchanged = try await controller.configuration()
        XCTAssertFalse(unchanged.enabled(key.rawValue))
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
        entries[try index(.preferredLocale)] = "fr_FR"
        entries[try index(.postProcessingTemperature)] = "0.6"
        entries[try index(.postProcessingOutputLanguage)] = "French"
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
        do { try await controller.importConfiguration(path: file.path); XCTFail("Invalid import accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Hold threshold"))
        }
        var entries = before.entries
        entries[try index(.postProcessingTemperature)] = "2"
        do { try await controller.saveConfiguration(entries); XCTFail("Invalid temperature accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Temperature"))
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
    }

    func testHUDPreferencesGatePresentationAndLiveText() async throws {
        var entries = try await controller.configuration().entries
        entries[try index(.showLiveTranscriptInHUD)] = "0"
        try await controller.saveConfiguration(entries)
        let id = UUID()
        await controller.beginHUD(id, .recording(profile: nil, liveText: "Synthetic speech"))
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "")
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .recording)
        await controller.finishHUD(id, .success("Done"))
        entries[try index(.showHUD)] = "0"
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
        entries[try index(.preferredLocale)] = "de_DE"
        do { try await controller.saveConfiguration(entries); XCTFail("Failed save accepted") } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let file = directory.appendingPathComponent("import.json")
        try Data(#"{"version":1,"preferences":{"preferredLocale":"fr_FR"}}"#.utf8).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Failed import accepted") } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after.entries, before.entries)
        XCTAssertEqual(try Data(contentsOf: settingsURL), saved)
        XCTAssertEqual(effects.writes, 1)
    }

    func testOversizedAndUnsupportedImportsLeaveSettingsUnchanged() async throws {
        let before = try await controller.configuration()
        let file = directory.appendingPathComponent("invalid.json")
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        do { try await controller.importConfiguration(path: file.path); XCTFail("Oversized import accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("1 MB"))
        }
        try Data(#"{"version":2,"preferences":{}}"#.utf8).write(to: file)
        do {
            try await controller.importConfiguration(path: file.path)
            XCTFail("Unsupported version accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("version"))
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
    }

    func testChangingPostProcessingDoesNotResetAdvancedPreferences() async throws {
        var entries = try await controller.configuration().entries
        entries[try index(.postProcessingTemperature)] = "0.7"
        entries[try index(.postProcessingOutputLanguage)] = "German"
        try await controller.saveConfiguration(entries)
        await controller.savePostProcessing(enabled: false, modelIndex: 0, prompt: "Custom", key: "")
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved.temperature, 0.7)
        XCTAssertEqual(saved.outputLanguage, "German")
        XCTAssertEqual(saved.customPrompt, "Custom")
    }

    func testShortenedErrorDurationPreservesLiveTextPolicyAndSuccessTiming() async throws {
        var entries = try await controller.configuration().entries
        entries[try index(.showLiveTranscriptInHUD)] = "0"
        entries[try index(.shortenErrorDisplay)] = "1"
        try await controller.saveConfiguration(entries)
        let id = UUID()
        await controller.beginHUD(id, .recording(profile: nil, liveText: "Synthetic speech"))
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "")
        await controller.finishHUD(id, .failure("Synthetic error"))
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, 3.6)
        let replacement = UUID()
        await controller.beginHUD(replacement, .recording(profile: nil))
        await controller.finishHUD(id, .failure("Old error"))
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .recording)
        XCTAssertNil(FakeLog.shared.huds.last?.displayDuration)
        await controller.finishHUD(replacement, .success("Completed"))
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, 2.4)
        entries[try index(.shortenErrorDisplay)] = "0"
        try await controller.saveConfiguration(entries)
        await controller.beginHUD(id, .recording(profile: nil))
        await controller.finishHUD(id, .failure("Synthetic error"))
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, 6.0)
    }

    func testOversizedExportDoesNotReplaceExistingFile() async throws {
        let file = directory.appendingPathComponent("large.json")
        let preferences = try DesktopConfiguration(values: [
            "opaque": AnyCodable(.string(String(repeating: "a", count: 1_000_000)))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        var entries = try await controller.configuration().entries
        entries[try index(.transcriptionKeywords)] = String(repeating: "a", count: 65_535)
        try await controller.saveConfiguration(entries)
        let original = Data("Existing export".utf8)
        try original.write(to: file)
        do { try await controller.exportConfiguration(path: file.path); XCTFail("Oversized export accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("1 MB"))
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCompactHUDPolicyPreservesTimersRetractionsAndReplacementIdentity() async throws {
        var entries = try await controller.configuration().entries
        let compactIndex = try index(.showCompactHUD)
        entries[compactIndex] = "1"
        entries[try index(.showLiveTranscriptInHUD)] = "0"
        entries[try index(.shortenErrorDisplay)] = "1"
        try await controller.saveConfiguration(entries)
        let first = UUID()
        await controller.beginHUD(first, .recording(profile: nil, liveText: "Synthetic speech"))
        XCTAssertEqual(FakeLog.shared.huds.last?.compact, true)
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "")
        XCTAssertNil(FakeLog.shared.huds.last?.displayDuration)
        await controller.finishHUD(first, .failure("Synthetic error"))
        XCTAssertEqual(FakeLog.shared.huds.last?.compact, true)
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, 3.6)

        entries[try index(.showLiveTranscriptInHUD)] = "1"
        try await controller.saveConfiguration(entries)
        let second = UUID()
        await controller.beginHUD(second, .recording(profile: nil, liveText: "Latest words"))
        await controller.hud(second, .recording(profile: nil, liveText: ""))
        XCTAssertEqual(FakeLog.shared.huds.last?.compact, true)
        XCTAssertNil(FakeLog.shared.huds.last?.liveText)
        await controller.finishHUD(first, .failure("Obsolete error"))
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .recording)
        await controller.finishHUD(second, .success("Completed"))
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, 2.4)

        entries[compactIndex] = "0"
        try await controller.saveConfiguration(entries)
        await controller.beginHUD(first, .recording(profile: nil, liveText: "Full card"))
        XCTAssertEqual(FakeLog.shared.huds.last?.compact, false)
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "Full card")
        await controller.finishHUD(first, .success("Completed"))
        entries[try index(.showHUD)] = "0"
        entries[compactIndex] = "1"
        try await controller.saveConfiguration(entries)
        await controller.beginHUD(UUID(), .recording(profile: nil))
        XCTAssertEqual(FakeLog.shared.huds.last, .hidden)
    }
}
