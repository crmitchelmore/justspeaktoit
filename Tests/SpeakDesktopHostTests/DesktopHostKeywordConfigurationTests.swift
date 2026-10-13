import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostKeywordConfigurationTests: XCTestCase {
    private var directory: URL!
    private var effects: SettingsWriteEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyword-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SettingsWriteEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func importConflict() async throws {
        let path = directory.appendingPathComponent("conflict.json")
        let document = #"""
        {"version":1,"preferences":{
          "transcriptionKeywords":"","assemblyAIKeyterms":"Recoverable words",
          "transcriptionKeywordsLastReconciled":"Original","future":true
        }}
        """#
        try Data(document.utf8).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }

    func testImportRecoveryExportAndReloadPreserveClearAndSelectedRecovery() async throws {
        try await importConflict()
        let before = try await controller.configuration()
        XCTAssertEqual(before.text("transcriptionKeywords"), "")
        XCTAssertEqual(before.recoveredKeywords, ["Recoverable words"])
        XCTAssertEqual(FakeLog.shared.allStatuses.last?.contains("Preserved but not applied: future"), true)
        try await controller.recoverConfigurationKeywords(before.entries, selected: "Recoverable words")
        let after = try await controller.configuration()
        XCTAssertEqual(after.text("assemblyAIKeyterms"), "Recoverable words")
        XCTAssertTrue(after.recoveredKeywords.isEmpty)
        XCTAssertEqual(after.values["future"], before.values["future"])
        let export = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: export.path)
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any]
        XCTAssertNotNil(exported?["preferences"])
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let reloaded = try await controller.configuration()
        for field in DesktopConfiguration.fields {
            switch field.kind {
            case .text, .choice: XCTAssertEqual(reloaded.text(field.key), after.text(field.key))
            case .boolean: XCTAssertEqual(reloaded.enabled(field.key), after.enabled(field.key))
            case .number: XCTAssertEqual(reloaded.number(field.key), after.number(field.key))
            }
        }
        XCTAssertEqual(reloaded.recoveredKeywords, after.recoveredKeywords)
        XCTAssertEqual(
            reloaded.values["transcriptionKeywordsLastReconciled"], after.values["transcriptionKeywordsLastReconciled"]
        )
        XCTAssertEqual(reloaded.values["future"], after.values["future"])
    }

    func testRefusedRecoveryWriteAndInvalidSelectionLeaveDiskAndActiveClearUnchanged() async throws {
        try await importConflict()
        let before = try await controller.configuration()
        let settings = directory.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: settings)
        effects.refusesWrites = true
        do {
            try await controller.recoverConfigurationKeywords(before.entries, selected: "Recoverable words")
            XCTFail("A refused recovery write was accepted.")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        do {
            try await controller.recoverConfigurationKeywords(before.entries, selected: "Removed or replaced edit")
            XCTFail("A removed recovery edit was accepted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Recovered keyword edit"))
        }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: settings), saved)
    }
}
