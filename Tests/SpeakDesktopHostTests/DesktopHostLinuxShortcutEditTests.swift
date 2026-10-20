import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostLinuxShortcutEditTests: XCTestCase {
    private var cleanupController: DesktopHostController<FakePlatform>?
    private var cleanupDirectory: URL?

    override func tearDown() async throws {
        if let cleanupController { await cleanupController.close() }
        if let cleanupDirectory { try FileManager.default.removeItem(at: cleanupDirectory) }
    }

    private func accepted(_ edit: DesktopHostShortcutEdit) throws -> DesktopShortcutBindings {
        guard case .accepted(let bindings, _) = edit else {
            throw DesktopHostError(message: "Unexpected refused edit: \(edit)")
        }
        return bindings
    }

    private func rows(_ bindings: DesktopShortcutBindings) -> [DesktopHostLinuxShortcutRow] {
        DesktopShortcutAction.allCases.map { action in
            let binding = bindings[action]
            let unset = binding.keyCode == 0 && binding.modifiers.isEmpty && !binding.isEnabled
            return .init(
                action: action, chord: unset ? nil : binding.linuxChord,
                isEnabled: binding.isEnabled, isGlobal: binding.isGlobal, replacesKey: true
            )
        }
    }

    func testSwitchOnlyEditAndExplicitClear_DistinguishAnUnsupportedMacKey() throws {
        let mac = DesktopShortcutBinding(keyCode: 38, modifiers: [.control, .shift], isGlobal: false)
        let base = DesktopShortcutBindings([.showHistory: mac], preservedEntries: ["future": .bool(true)])
        let switched = try accepted(base.editingLinux([
            .init(action: .showHistory, chord: nil, isEnabled: false, isGlobal: true, replacesKey: false)
        ], runnable: [.showHistory]))
        XCTAssertEqual(switched[.showHistory].keyCode, mac.keyCode)
        XCTAssertEqual(switched[.showHistory].modifiers, mac.modifiers)
        XCTAssertFalse(switched[.showHistory].isEnabled)
        XCTAssertTrue(switched[.showHistory].isGlobal)
        let cleared = try accepted(base.editingLinux([
            .init(action: .showHistory, chord: nil, isEnabled: true, isGlobal: false, replacesKey: true)
        ], runnable: [.showHistory]))
        XCTAssertEqual(cleared[.showHistory].keyCode, 0)
        XCTAssertEqual(cleared[.showHistory].modifiers, [])
        XCTAssertFalse(cleared[.showHistory].isEnabled)
        XCTAssertEqual(cleared.preservedEntries, base.preservedEntries)
    }

    func testAllPresets_RestoreCanonicalSpaceEscapeAndPreserveUnknownEntries() throws {
        var base = DesktopShortcutBindings([:], preservedEntries: ["future": .string("keep")])
        base[.stopTTS] = .init(keyCode: 38, modifiers: [.command, .option], isGlobal: false)
        base[.pauseResumeTTS] = .init(keyCode: 37, modifiers: [.command, .option], isGlobal: false)
        for preset in DesktopShortcutPreset.allCases {
            let expected = base.applying(preset)
            let result = try accepted(base.editingLinux(rows(expected), runnable: Set(DesktopShortcutAction.allCases)))
            XCTAssertEqual(result, expected, preset.rawValue)
        }
    }

    func testInvalidUnknownDuplicateAndUnmodifiedTypingEdits_AreRefused() {
        let base = DesktopShortcutBindings.defaults
        let bad: [DesktopShortcutLinuxChord] = [
            .init(keysym: UInt32.max, modifiers: 4), .init(keysym: 0x6A, modifiers: 0),
            .init(keysym: 0x73, modifiers: 5)
        ]
        for chord in bad {
            var unset = base
            unset[.openDataMigrationSettings] = DesktopShortcutBinding(
                keyCode: 0, modifiers: [], isGlobal: false, isEnabled: false
            )
            guard case .refused = unset.editingLinux([
                .init(action: .showHistory, chord: chord, isEnabled: true, isGlobal: false, replacesKey: true)
            ], runnable: Set(DesktopShortcutAction.allCases)) else { return XCTFail("Invalid key accepted") }
        }
        guard case .refused = base.editingLinux([
            .init(action: .openDataMigrationSettings, chord: nil,
                  isEnabled: true, isGlobal: false, replacesKey: false)
        ], runnable: [.openDataMigrationSettings]) else { return XCTFail("Unset key enabled") }
    }

    private func wire() -> String {
        let revision = "00000000-0000-0000-0000-000000000001"
        let request = "00000000-0000-0000-0000-000000000002"
        return "\(revision)\t\(request)\n" + rows(.defaults).map { row in
            "\(row.action.rawValue)\t\(row.chord?.keysym ?? 0)\t\(row.chord?.modifiers ?? 0)"
                + "\t\(row.isEnabled ? 1 : 0)\t\(row.isGlobal ? 1 : 0)\t0\n"
        }.joined()
    }

    func testDraftProtocol_RequiresCompleteUniqueActionsAndStrictFields() throws {
        let value = wire()
        let request = try DesktopHostLinuxShortcutRequest(wire: value)
        XCTAssertEqual(request.rows.map(\.action), DesktopShortcutAction.allCases)
        XCTAssertFalse(request.rows.contains(where: \.replacesKey))
        XCTAssertThrowsError(try DesktopHostLinuxShortcutRequest(wire: String(value.dropLast())))
        XCTAssertThrowsError(try DesktopHostLinuxShortcutRequest(wire: String(repeating: "x", count: 32769)))
        for fields in [
            ["unknown", "100", "4", "1", "0", "0"],
            ["openDashboard", "-1", "4", "1", "0", "0"],
            ["openDashboard", "100", "16", "1", "0", "0"],
            ["openDashboard", "100", "4", "true", "0", "0"],
            ["openDashboard", "100", "4", "1", "0", "2"],
            ["startStopRecording", "100", "4", "1", "0", "0"]
        ] {
            var lines = value.components(separatedBy: "\n")
            lines[1] = fields.joined(separator: "\t")
            XCTAssertThrowsError(try DesktopHostLinuxShortcutRequest(wire: lines.joined(separator: "\n")))
        }
    }

    func testConditionalSave_RejectsStaleDraftWithoutChangingPersistedSettings() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-cas-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupDirectory = directory
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        cleanupController = controller
        let base = await controller.shortcutBindings
        let changed = base.applying(.off)
        try await controller.saveShortcutBindings(changed, replacing: base)
        let file = directory.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: file)
        do {
            try await controller.saveShortcutBindings(base.applying(.essentials), replacing: base)
            XCTFail("Stale draft overwrote newer bindings")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Saved shortcuts changed"))
        }
        let actual = await controller.shortcutBindings
        XCTAssertEqual(actual, changed)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    func testConditionalSave_FailedWriteLeavesMemoryAndDiskUnchanged() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-write-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupDirectory = directory
        let effects = SettingsWriteEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        cleanupController = controller
        let base = await controller.shortcutBindings
        try await controller.saveShortcutBindings(base)
        let file = directory.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: file)
        effects.refusesWrites = true
        do {
            try await controller.saveShortcutBindings(base.applying(.off), replacing: base)
            XCTFail("Failed write accepted")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let actual = await controller.shortcutBindings
        XCTAssertEqual(actual, base)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }
}
