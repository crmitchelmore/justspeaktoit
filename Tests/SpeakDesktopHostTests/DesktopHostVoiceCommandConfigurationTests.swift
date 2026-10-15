import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostVoiceCommandConfigTests: XCTestCase {
    func testCanonicalDefaultsKindsAndDependenciesAndStrictValidation() throws {
        let preferences = try DesktopConfiguration()
        XCTAssertTrue(preferences.enabled("voiceCommandsEnabled"))
        XCTAssertEqual(preferences.text("clipboardInsertionTriggers"), "")
        let enabled = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == "voiceCommandsEnabled" })
        let triggers = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == "clipboardInsertionTriggers" })
        XCTAssertEqual(enabled.group, "General")
        XCTAssertEqual(triggers.group, "General")
        XCTAssertEqual(triggers.enabledBy, enabled.key)
        XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: enabled.key)?.kind, .boolean)
        XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: triggers.key)?.kind, .text)
        for invalid in [AnyCodable(.int(1)), AnyCodable(.string("true")), AnyCodable(.null)] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [enabled.key: invalid]))
        }
        XCTAssertThrowsError(try DesktopConfiguration(values: [triggers.key: AnyCodable(.bool(false))]))
        XCTAssertThrowsError(try DesktopConfiguration(values: [triggers.key: AnyCodable(.string("a\0b"))]))
    }

    func testSaveRelaunchTransferAndClearKeepOneConfigurationAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let effects = VoiceCommandEffects()
        let first = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        var entries = try await first.configuration().entries
        let enabledIndex = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "voiceCommandsEnabled" })
        let triggersIndex = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == "clipboardInsertionTriggers"
        })
        entries[enabledIndex] = "0"
        entries[triggersIndex] = "my snippet, paste"
        try await first.saveConfiguration(entries)
        let exported = directory.appendingPathComponent("preferences.json")
        try await first.exportConfiguration(path: exported.path)
        await first.close()
        let second = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        let restored = try await second.configuration()
        XCTAssertFalse(restored.enabled("voiceCommandsEnabled"))
        XCTAssertEqual(restored.text("clipboardInsertionTriggers"), "my snippet, paste")
        let disk = try JSONDecoder().decode(
            [String: AnyCodable].self, from: Data(contentsOf: directory.appendingPathComponent("settings.json"))
        )
        XCTAssertNil(disk["voiceCommandsEnabled"])
        XCTAssertNil(disk["clipboardInsertionTriggers"])
        var cleared = restored.entries
        cleared[triggersIndex] = ""
        try await second.saveConfiguration(cleared)
        let afterClear = try await second.configuration()
        XCTAssertEqual(afterClear.text("clipboardInsertionTriggers"), "")
        XCTAssertTrue(VoiceCommandProcessor.containsClipboardCommand(in: "copy pasta", customTriggers: ""))
        try await second.importConfiguration(path: exported.path)
        let imported = try await second.configuration()
        XCTAssertEqual(imported, restored)
        XCTAssertEqual(effects.reads, 0, "Transfer must not read the clipboard or execute voice commands")
        await second.close()
    }
}
