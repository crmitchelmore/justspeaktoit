import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostLegacyPronunciationTests: XCTestCase {
    private let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue

    func testLegacyEditor_CRUDPreservesModernEntriesKeywordsSuppressionAndUnknownPreferences() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await seed(controller, root: root, dictionary: ["Legacy": "Spoken\nform\t%"])
        _ = try await controller.vocabularyEvent(kind: 1, payload: DesktopVocabularyWire.encode([
            "save", "", "Modern", "Modern spoken", "", "Technical", "false", "false", ""
        ]))
        let modern = try await controller.vocabularyPresentation(kind: 1)
        let before = try await controller.configuration()
        let settings = root.appendingPathComponent("settings.json")
        let bytes = try Data(contentsOf: settings)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("A local dictionary edit read credentials.") }
        let rows = try await legacyRows(controller)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][1], "Legacy")
        XCTAssertEqual(rows[0][2], "Spoken\nform\t%")
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        _ = try await send(controller, ["save", rows[0][0], " Renamed ", " New spoken "])
        var configuration = try await controller.configuration()
        XCTAssertEqual(configuration.legacyPronunciationDictionary, ["Renamed": "New spoken"])
        for key in before.values.keys where key != dictionaryKey {
            XCTAssertEqual(configuration.values[key], before.values[key], key)
        }
        let renamedRows = try await legacyRows(controller)
        XCTAssertEqual(renamedRows.first?[1], "Renamed")
        let changedModern = try await controller.vocabularyPresentation(kind: 1)
        XCTAssertEqual(changedModern, modern)
        _ = try await send(controller, ["save", "", "Additional", "Added"])
        let additionalRows = try await legacyRows(controller)
        let renamed = try XCTUnwrap(additionalRows.first { $0[1] == "Renamed" })
        _ = try await send(controller, ["delete", renamed[0], renamed[1], renamed[2]])
        configuration = try await controller.configuration()
        XCTAssertEqual(configuration.legacyPronunciationDictionary, ["Additional": "Added"])
        FakeLog.shared.reset()
        await controller.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let restored = try await restarted.configuration()
        XCTAssertEqual(restored.legacyPronunciationDictionary, ["Additional": "Added"])
        XCTAssertEqual(restored.values["futureSetting"], before.values["futureSetting"])
        let export = root.appendingPathComponent("legacy-export.json")
        try await restarted.exportConfiguration(path: export.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: export))
        XCTAssertEqual(document.preferences.legacyPronunciationDictionary, ["Additional": "Added"])
        await restarted.close()
    }

    func testLegacyEditor_RejectsStaleRowsAndDuplicateRenamesWithoutLosingOtherEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await seed(controller, root: root, dictionary: ["A": "First", "B": "Second"])
        let rows = try await legacyRows(controller)
        // swiftlint:disable:next identifier_name
        let a = try XCTUnwrap(rows.first { $0[1] == "A" })
        _ = try await send(controller, ["save", a[0], "A", "Changed"])
        await expectRefusal(controller, fields: ["delete", a[0], "A", "First"], message: "changed")
        await expectRefusal(controller, fields: ["save", a[0], "A", "Stale"], message: "changed")
        let changedRows = try await legacyRows(controller)
        let current = try XCTUnwrap(changedRows.first { $0[1] == "A" })
        await expectRefusal(controller, fields: ["save", current[0], "B", "Collision"], message: "already exists")
        await expectRefusal(controller, fields: ["save", "", "B", "Collision"], message: "already exists")
        let configuration = try await controller.configuration()
        XCTAssertEqual(configuration.legacyPronunciationDictionary, ["A": "Changed", "B": "Second"])
        await controller.close()
    }

    func testLegacyEditor_RefusedPersistenceLeavesDiskRuntimeAndRetryIdentityIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        try await seed(controller, root: root, dictionary: ["A": "Before"])
        let rows = try await legacyRows(controller)
        let row = try XCTUnwrap(rows.first)
        let before = try await controller.configuration()
        let file = root.appendingPathComponent("settings.json")
        let bytes = try Data(contentsOf: file)
        effects.refusesWrites = true
        do {
            _ = try await send(controller, ["save", row[0], "A", "After"])
            XCTFail("A refused write was accepted.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        effects.refusesWrites = false
        _ = try await send(controller, ["save", row[0], "A", "After"])
        let retried = try await controller.configuration()
        XCTAssertEqual(retried.legacyPronunciationDictionary, ["A": "After"])
        await controller.close()
    }

    func testLegacyEditor_RejectsMalformedAndUnrepresentableChangesWithoutTruncatingStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        try await seed(controller, root: root, dictionary: [:])
        for fields in [["save"], ["defaults", "", "", ""], ["save", "", " ", "spoken"],
                       ["save", "", "Word", ""], ["save", "not base64", "Word", "spoken"],
                       ["save", "", "Bad\0Word", "spoken"],
                       ["save", "", "Word", String(repeating: "x", count: 65_536)]] {
            await expectRefusal(controller, fields: fields)
        }
        let before = try await controller.configuration()
        XCTAssertTrue(before.legacyPronunciationDictionary.isEmpty)
        try await seed(controller, root: root, dictionary: ["Imported\0Word": "Preserved"])
        do {
            _ = try await controller.vocabularyPresentation(kind: 4)
            XCTFail("An unrepresentable imported word was silently truncated.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cannot fit safely")) }
        let after = try await controller.configuration()
        XCTAssertEqual(after.legacyPronunciationDictionary, ["Imported\0Word": "Preserved"])
        await controller.close()
    }

    private func seed(
        _ controller: DesktopHostController<FakePlatform>, root: URL, dictionary: [String: String]
    ) async throws {
        let configuration = try DesktopConfiguration(values: [
            dictionaryKey: AnyCodable(.object(dictionary.mapValues { .string($0) })),
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue:
                AnyCodable(.array([.string("hidden")])),
            "futureSetting": AnyCodable(.object(["value": .string("retained")]))
        ])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("legacy-fixture.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: file)
        try await controller.importConfiguration(path: file.path)
    }

    private func legacyRows(_ controller: DesktopHostController<FakePlatform>) async throws -> [[String]] {
        let presentation = try await controller.vocabularyPresentation(kind: 4)
        return try presentation.components(separatedBy: "\n").dropFirst().map(DesktopVocabularyWire.decode)
    }

    private func send(_ controller: DesktopHostController<FakePlatform>, _ fields: [String]) async throws -> String {
        try await controller.vocabularyEvent(kind: 4, payload: DesktopVocabularyWire.encode(fields))
    }

    private func expectRefusal(
        _ controller: DesktopHostController<FakePlatform>, fields: [String], message: String? = nil
    ) async {
        do {
            _ = try await send(controller, fields)
            XCTFail("An invalid or stale legacy edit was accepted.")
        } catch {
            if let message { XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription) }
        }
    }
}
