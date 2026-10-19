import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostPronunciationPreferenceTests: XCTestCase {
    func testRootOnlyStartup_AdoptsLegacyHintsAndSuppressionWithoutCopyingValues() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        let settings: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("not sent"), "Beta": .string("not sent")])),
            ignoredKey: AnyCodable(.array([.string("beta")]))
        ]
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.liveOptions.keywords, [])
        XCTAssertEqual(configuration.liveOptions.assemblyAIKeyterms, ["Alpha"])
        XCTAssertEqual(configuration.values[dictionaryKey], settings[dictionaryKey])
        XCTAssertEqual(configuration.values[ignoredKey], settings[ignoredKey])
        await controller.close()
    }

    func testRootAndNestedStartup_ExportAndRestartPreserveNestedLegacyHints() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        let nested = AnyCodable.JSONValue.object(["Nested": .string("retained phonetic value")])
        let settings: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            dictionaryKey: AnyCodable(.object(["Root": .string("not the effective map")])),
            ignoredKey: AnyCodable(.array([.string("nested")])),
            "configuration": AnyCodable(.object([dictionaryKey: nested, ignoredKey: .array([])]))
        ]
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let effective = try await controller.configuration()
        XCTAssertEqual(effective.liveOptions.assemblyAIKeyterms, ["Nested"])
        XCTAssertEqual(effective.values[dictionaryKey], AnyCodable(nested))
        try await controller.saveConfiguration(effective.entries)
        let exported = root.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: exported.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: exported))
        XCTAssertEqual(document.preferences.values[dictionaryKey], AnyCodable(nested))
        XCTAssertEqual(document.preferences.values[ignoredKey], AnyCodable(.array([])))
        await controller.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let restored = try await restarted.configuration()
        XCTAssertEqual(restored.liveOptions.assemblyAIKeyterms, ["Nested"])
        XCTAssertEqual(restored.values[dictionaryKey], AnyCodable(nested))
        await restarted.close()
    }

    func testMalformedImportAndRefusedKeywordClear_LeaveRuntimeAndDiskUnchanged() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let initial = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("al-fa")]))
        ])
        let transfer = root.appendingPathComponent("import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: initial)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        let before = try await controller.configuration()
        let settingsFile = root.appendingPathComponent("settings.json")
        let originalBytes = try Data(contentsOf: settingsFile)
        let malformed = #"{"version":1,"preferences":{"ttsPronunciationDictionary":{"Alpha":42}}}"#
        try Data(malformed.utf8).write(to: transfer)
        do {
            try await controller.importConfiguration(path: transfer.path)
            XCTFail("A non-text legacy pronunciation was accepted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Legacy pronunciation dictionary"))
        }
        var entries = before.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = ""
        effects.refusesWrites = true
        do {
            try await controller.saveConfiguration(entries)
            XCTFail("A refused keyword clear changed pronunciation suppression.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: settingsFile), originalBytes)
        await controller.close()
    }
}
