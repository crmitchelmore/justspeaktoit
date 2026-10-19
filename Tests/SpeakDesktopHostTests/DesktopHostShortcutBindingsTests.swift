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

    private func rows(_ bindings: DesktopShortcutBindings) -> [DesktopHostShortcutRow] {
        DesktopShortcutAction.allCases.map { bindings.editorRow(for: $0) }
    }

    private func replacing(
        _ rows: [DesktopHostShortcutRow], _ action: DesktopShortcutAction,
        chord: DesktopShortcutWindowsChord?, enabled: Bool = true, global: Bool = false
    ) -> [DesktopHostShortcutRow] {
        rows.map {
            $0.action == action
                ? DesktopHostShortcutRow(action: action, chord: chord, isEnabled: enabled, isGlobal: global) : $0
        }
    }

    func testEditingMapsWindowsCombinationsToMacBindings() throws {
        let ctrlAltJ = DesktopShortcutWindowsChord(modifiers: 0x3, virtualKey: 0x4A)
        let edit = DesktopShortcutBindings.defaults.editing(
            replacing(rows(.defaults), .startStopRecording, chord: ctrlAltJ, global: true),
            runnable: [.startStopRecording]
        )
        guard case .accepted(let edited, let warnings) = edit else { return XCTFail("Refused: \(edit)") }
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(
            edited[.startStopRecording],
            DesktopShortcutBinding(keyCode: 38, modifiers: [.command, .option], isGlobal: true, isEnabled: true)
        )
        XCTAssertEqual(edited.editorRow(for: .startStopRecording).chord, ctrlAltJ)

        let cleared = DesktopShortcutBindings.defaults.editing(
            replacing(rows(.defaults), .showHistory, chord: nil), runnable: [.showHistory]
        )
        guard case .accepted(let clearedBindings, _) = cleared else { return XCTFail("Refused clear") }
        XCTAssertNil(clearedBindings.editorRow(for: .showHistory).chord)
        XCTAssertFalse(clearedBindings[.showHistory].isEnabled)
    }

    func testEditingKeepsMacOnlyBindingsWhenOnlySwitchesChange() throws {
        var bindings = DesktopShortcutBindings.defaults
        let macOnly = DesktopShortcutBinding(keyCode: 38, modifiers: [.control, .shift], isGlobal: false)
        bindings[.showHistory] = macOnly
        XCTAssertNil(bindings.editorRow(for: .showHistory).chord)
        let edit = bindings.editing(
            replacing(rows(bindings), .showHistory, chord: nil, enabled: false), runnable: [.showHistory]
        )
        guard case .accepted(let edited, _) = edit else { return XCTFail("Refused: \(edit)") }
        XCTAssertEqual(edited[.showHistory].keyCode, macOnly.keyCode)
        XCTAssertEqual(edited[.showHistory].modifiers, macOnly.modifiers)
        XCTAssertFalse(edited[.showHistory].isEnabled)
    }

    func testEditingRefusesDuplicatesBlockedAndTypingCombinations() throws {
        let ctrlShiftS = DesktopShortcutWindowsChord(modifiers: 0x6, virtualKey: 0x53)
        let duplicate = DesktopShortcutBindings.defaults.editing(
            replacing(rows(.defaults), .showHistory, chord: ctrlShiftS), runnable: [.showHistory]
        )
        guard case .refused(let message) = duplicate else { return XCTFail("Duplicate accepted") }
        XCTAssertTrue(message.contains(DesktopShortcutAction.startStopRecording.displayName))

        let plainJ = DesktopShortcutWindowsChord(modifiers: 0, virtualKey: 0x4A)
        guard case .refused = DesktopShortcutBindings.defaults.editing(
            replacing(rows(.defaults), .showHistory, chord: plainJ), runnable: [.showHistory]
        ) else { return XCTFail("Unmodified letter accepted") }

        guard case .refused(let blocked) = DesktopShortcutBindings.defaults.editing(
            rows(.defaults), runnable: [.startStopRecording],
            blocking: { _, chord in chord == ctrlShiftS ? "the dictation shortcut" : nil }
        ) else { return XCTFail("Dictation shortcut accepted") }
        XCTAssertTrue(blocked.contains("the dictation shortcut"))
    }

    func testImportedDuplicatesAndWarningsOnlyConcernEditedRows() throws {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.showHistory] = bindings[.openDashboard]
        let ctrlAltK = DesktopShortcutWindowsChord(modifiers: 0x3, virtualKey: 0x4B)
        let warnAll: (DesktopShortcutAction, DesktopShortcutWindowsChord) -> String? = { _, _ in "the sidebar" }
        let edit = bindings.editing(
            replacing(rows(bindings), .openCorrections, chord: ctrlAltK),
            runnable: Set(DesktopShortcutAction.allCases), warning: warnAll
        )
        guard case .accepted(_, let warnings) = edit else { return XCTFail("Imported duplicate blocked: \(edit)") }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix(DesktopShortcutAction.openCorrections.displayName))
    }
}
