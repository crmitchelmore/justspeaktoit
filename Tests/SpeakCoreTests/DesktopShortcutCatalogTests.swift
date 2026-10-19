import XCTest

@testable import SpeakCore

final class DesktopShortcutCatalogTests: XCTestCase {
    func testCatalogue_keepsTheMacIdentifiersInOrder() {
        XCTAssertEqual(DesktopShortcutAction.allCases.map(\.rawValue), [
            "openDashboard", "startStopRecording", "speakSelectedText", "speakClipboard", "pauseResumeTTS",
            "stopTTS", "openSettings", "showHistory", "openVoiceOutput", "openCorrections", "openTroubleshooting",
            "openTranscriptionSettings", "openPostProcessingSettings", "openDataMigrationSettings",
            "openProfilesSettings", "openVoiceOutputSettings", "openPronunciationSettings", "openAPIKeysSettings",
            "openKeyboardSettings", "openPermissionsSettings", "openCompareModelsSettings", "openAboutSettings",
            "quickVoice1", "quickVoice2", "quickVoice3", "pasteLastHistoryItem", "editSelectionByVoice"
        ])
        XCTAssertEqual(DesktopShortcutBindings.preferenceKey, "customShortcutBindings")
    }

    func testDefaults_matchTheMac() {
        XCTAssertEqual(
            DesktopShortcutAction.startStopRecording.defaultBinding,
            DesktopShortcutBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: false, isEnabled: true)
        )
        XCTAssertEqual(
            DesktopShortcutAction.speakSelectedText.defaultBinding,
            DesktopShortcutBinding(keyCode: 17, modifiers: [.command, .shift], isGlobal: true, isEnabled: true)
        )
        XCTAssertEqual(DesktopShortcutAction.stopTTS.defaultBinding.keyCode, 53)
        XCTAssertTrue(DesktopShortcutAction.stopTTS.defaultBinding.modifiers.isEmpty)
        XCTAssertFalse(DesktopShortcutAction.openDataMigrationSettings.defaultBinding.isEnabled)
        XCTAssertEqual(
            DesktopShortcutAction.allCases.filter(\.supportsGlobalShortcut),
            [.startStopRecording, .speakSelectedText, .speakClipboard, .pasteLastHistoryItem, .editSelectionByVoice]
        )
    }

    func testMacArrayEncoding_roundTrips() throws {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.showHistory] = DesktopShortcutBinding(keyCode: 4, modifiers: [.command, .option], isGlobal: false)
        let value = bindings.preferenceValue
        guard case .array(let items) = value.storage else { return XCTFail("Expected the Mac array form") }
        XCTAssertEqual(items.count, DesktopShortcutAction.allCases.count * 2)
        XCTAssertEqual(items.first, .string("openDashboard"))
        XCTAssertEqual(DesktopShortcutBindings(preference: value), bindings)

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(DesktopShortcutBindings(preference: decoded), bindings)
    }

    func testMacJSON_decodesWithCodableBinding() throws {
        let json = Data(#"{"keyCode":1,"modifiersRaw":1179648,"isGlobal":true,"isEnabled":false}"#.utf8)
        let binding = try JSONDecoder().decode(DesktopShortcutBinding.self, from: json)
        XCTAssertEqual(binding.modifiers, [.command, .shift])
        XCTAssertTrue(binding.isGlobal)
        XCTAssertFalse(binding.isEnabled)
    }

    func testLegacyDefaults_migrateToCurrentDefaults() {
        let legacy = DesktopShortcutAction.openDashboard.legacyDefaultBindings[0]
        let preference = AnyCodable(.array([.string("openDashboard"), legacyValue(legacy)]))
        XCTAssertEqual(DesktopShortcutBindings(preference: preference)[.openDashboard],
                       DesktopShortcutAction.openDashboard.defaultBinding)
    }

    func testUnknownAndMalformedEntries() {
        let custom = DesktopShortcutBinding(keyCode: 5, modifiers: .command, isGlobal: false)
        let preference = AnyCodable(.array([
            .string("futureAction"), .object(["keyCode": .int(3)]),
            .string("showHistory"), .string("not a binding"),
            .string("openCorrections"), legacyValue(custom)
        ]))
        let bindings = DesktopShortcutBindings(preference: preference)
        XCTAssertEqual(bindings.preservedEntries["futureAction"], .object(["keyCode": .int(3)]))
        XCTAssertEqual(bindings[.showHistory], DesktopShortcutAction.showHistory.defaultBinding)
        XCTAssertEqual(bindings[.openCorrections], custom)
        guard case .array(let items) = bindings.preferenceValue.storage else { return XCTFail("array") }
        XCTAssertEqual(items[items.count - 2], .string("futureAction"))
    }

    func testPresetsAndReset() {
        let off = DesktopShortcutBindings.defaults.applying(.off)
        XCTAssertTrue(DesktopShortcutAction.allCases.allSatisfy { !off[$0].isEnabled })
        XCTAssertEqual(off.matchingPreset, .off)
        let essentials = DesktopShortcutBindings(preset: .essentials)
        XCTAssertTrue(essentials[.stopTTS].isEnabled)
        XCTAssertFalse(essentials[.showHistory].isEnabled)
        XCTAssertEqual(essentials.matchingPreset, .essentials)
        var custom = essentials
        custom[.stopTTS].isEnabled = false
        XCTAssertNil(custom.matchingPreset)
        XCTAssertEqual(custom.resettingToDefaults(), DesktopShortcutBindings.defaults)
        XCTAssertEqual(DesktopShortcutBindings.defaults.matchingPreset, .standard)
    }

    func testConflicts_reportDuplicatesAndReservedChords() {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.showHistory] = DesktopShortcutAction.openDashboard.defaultBinding
        bindings[.openCorrections] = DesktopShortcutBinding(keyCode: 45, modifiers: .command, isGlobal: false)
        let conflicts = bindings.conflicts()
        XCTAssertTrue(conflicts.contains(DesktopShortcutConflict(action: .showHistory,
                                                                 kind: .duplicate(.openDashboard))))
        XCTAssertTrue(conflicts.contains(DesktopShortcutConflict(action: .openCorrections,
                                                                 kind: .reserved("Minimize (System)"))))
        XCTAssertEqual(conflicts.filter(\.isBlocking).map(\.action), [.showHistory])
        XCTAssertTrue(DesktopShortcutBindings.defaults.conflicts().filter(\.isBlocking).isEmpty)
        XCTAssertTrue(bindings.conflicts(among: [.openDashboard, .openCorrections], reserved: [:]).isEmpty)
    }

    func testWindowsMapping() throws {
        let recording = DesktopShortcutAction.startStopRecording.defaultBinding
        XCTAssertEqual(recording.windowsChord, DesktopShortcutWindowsChord(
            modifiers: DesktopShortcutWindowsChord.control | DesktopShortcutWindowsChord.shift, virtualKey: 0x53
        ))
        XCTAssertEqual(recording.windowsDisplayName, "Ctrl+Shift+S")
        let chord = try XCTUnwrap(recording.windowsChord)
        XCTAssertEqual(DesktopShortcutBinding(windows: chord, isGlobal: false, isEnabled: true), recording)

        let macControl = DesktopShortcutBinding(keyCode: 0, modifiers: .control)
        XCTAssertNil(macControl.windowsChord)
        XCTAssertNotNil(macControl.windowsUnsupportedReason)
        XCTAssertTrue(macControl.windowsDisplayName.hasSuffix("(Mac only)"))
        XCTAssertNil(DesktopShortcutBinding(keyCode: 0, modifiers: [.command, .function]).windowsChord)
        XCTAssertNotNil(DesktopShortcutBinding(keyCode: 122, modifiers: [.command, .function]).windowsChord)
        XCTAssertNil(DesktopShortcutBinding(keyCode: 10, modifiers: .command).windowsChord)

        let f13 = DesktopShortcutBinding(keyCode: 105, modifiers: [])
        XCTAssertEqual(f13.windowsChord?.virtualKey, 0x7C)
        XCTAssertTrue(f13.windowsChord?.canWorkInOtherApps == true)
        XCTAssertFalse(DesktopShortcutAction.stopTTS.defaultBinding.windowsChord?.canWorkInOtherApps ?? true)
        XCTAssertEqual(DesktopShortcutKey.mac(114)?.windowsVirtualKey, 0x2D)
        XCTAssertEqual(DesktopShortcutKey.windows(0x83)?.name, "F20")
    }

    func testRecordable_matchesTheMacSingleKeyRule() {
        XCTAssertTrue(DesktopShortcutKey.isRecordable(macKeyCode: 0, hasModifiers: true))
        XCTAssertFalse(DesktopShortcutKey.isRecordable(macKeyCode: 0, hasModifiers: false))
        for code: UInt16 in [10, 64, 79, 80, 90, 105, 106, 107, 113, 114] {
            XCTAssertTrue(DesktopShortcutKey.isRecordable(macKeyCode: code, hasModifiers: false))
        }
    }

    func testConfiguration_replacesOnlyTheBindingsKey() throws {
        let configuration = try DesktopConfiguration(values: ["futurePreference": AnyCodable(.string("kept"))])
        let changed = try configuration.replacingShortcutBindings(DesktopShortcutBindings(preset: .off))
        XCTAssertEqual(changed.values["futurePreference"], configuration.values["futurePreference"])
        XCTAssertEqual(changed.shortcutBindings.matchingPreset, .off)
        XCTAssertEqual(configuration.shortcutBindings, .defaults)
    }

    private func legacyValue(_ binding: DesktopShortcutBinding) -> AnyCodable.JSONValue {
        .object([
            "keyCode": .int(Int(binding.keyCode)), "modifiersRaw": .int(Int(binding.modifiers.rawValue)),
            "isGlobal": .bool(binding.isGlobal), "isEnabled": .bool(binding.isEnabled)
        ])
    }
}
