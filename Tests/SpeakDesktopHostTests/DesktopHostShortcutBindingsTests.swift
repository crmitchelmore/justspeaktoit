import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostShortcutBindingsTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testSaveRestartExportAndImportKeepMacCompatibleBindings() async throws {
        let defaults = await controller.shortcutBindings
        XCTAssertEqual(defaults, DesktopShortcutBindings.defaults)
        var changed = defaults.applying(.essentials)
        changed[.stopTTS] = DesktopShortcutBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: false)
        try await controller.saveShortcutBindings(changed)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.shortcutBindings
        XCTAssertEqual(restored, changed)

        let file = directory.appendingPathComponent("shortcuts.json")
        try await controller.exportConfiguration(path: file.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        XCTAssertEqual(document.preferences.values[DesktopShortcutBindings.preferenceKey], changed.preferenceValue)

        try await controller.saveShortcutBindings(.defaults)
        try await controller.importConfiguration(path: file.path)
        let imported = await controller.shortcutBindings
        XCTAssertEqual(imported, changed)
    }

    func testHostWithoutShortcutsReportsBindingsAsPreserved() async throws {
        XCTAssertTrue(FakePlatform.shortcutConfigurationKeys.isEmpty)
        let file = directory.appendingPathComponent("import.json")
        let document: [String: AnyCodable] = [
            "version": AnyCodable(.int(1)),
            "preferences": AnyCodable(.object([
                DesktopShortcutBindings.preferenceKey: DesktopShortcutBindings(preset: .off).preferenceValue.storage
            ]))
        ]
        try JSONEncoder().encode(document).write(to: file)
        try await controller.importConfiguration(path: file.path)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains(DesktopShortcutBindings.preferenceKey) == true)
        let imported = await controller.shortcutBindings
        XCTAssertEqual(imported, DesktopShortcutBindings(preset: .off))
    }

    func testFailedWriteLeavesBindingsUnchanged() async throws {
        await controller.close()
        let effects = SettingsWriteEffects()
        effects.refusesWrites = true
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        do {
            try await controller.saveShortcutBindings(DesktopShortcutBindings(preset: .off))
            XCTFail("Failed write accepted")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let unchanged = await controller.shortcutBindings
        XCTAssertEqual(unchanged, .defaults)
    }
}
