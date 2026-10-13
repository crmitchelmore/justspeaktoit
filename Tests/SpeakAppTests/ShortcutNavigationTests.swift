import XCTest

@testable import SpeakApp

final class ShortcutNavigationTests: XCTestCase {
    func testSidebarItems_haveExpectedShortcutActions() {
        XCTAssertEqual(SidebarItem.dashboard.shortcutAction, .openDashboard)
        XCTAssertEqual(SidebarItem.history.shortcutAction, .showHistory)
        XCTAssertEqual(SidebarItem.voiceOutput.shortcutAction, .openVoiceOutput)
        XCTAssertEqual(SidebarItem.corrections.shortcutAction, .openCorrections)
        XCTAssertEqual(SidebarItem.troubleshooting.shortcutAction, .openTroubleshooting)
        XCTAssertEqual(SidebarItem.settings(.general).shortcutAction, .openSettings)
        XCTAssertEqual(SidebarItem.settings(.shortcuts).shortcutAction, .openKeyboardSettings)
    }

    func testNavigationShortcutDefaults_areAppLocalAndEnabled() {
        let actions: [ShortcutAction] = [
            .openDashboard,
            .showHistory,
            .openVoiceOutput,
            .openCorrections,
            .openTroubleshooting,
            .openSettings,
            .openTranscriptionSettings,
            .openPostProcessingSettings,
            .openProfilesSettings,
            .openVoiceOutputSettings,
            .openPronunciationSettings,
            .openAPIKeysSettings,
            .openKeyboardSettings,
            .openPermissionsSettings,
            .openCompareModelsSettings,
            .openDataMigrationSettings,
            .openAboutSettings
        ]

        for action in actions {
            let binding = action.defaultKeyBinding
            XCTAssertFalse(binding.isGlobal, "\(action.displayName) should be app-local")
            XCTAssertTrue(binding.isEnabled, "\(action.displayName) should be enabled by default")
        }
    }

    func testNavigationShortcutDefaults_useCompactMenuFriendlyBindings() {
        XCTAssertEqual(ShortcutAction.openDashboard.defaultKeyBinding.displayString, "⌘D")
        XCTAssertEqual(ShortcutAction.showHistory.defaultKeyBinding.displayString, "⌘Y")
        XCTAssertEqual(ShortcutAction.openVoiceOutput.defaultKeyBinding.displayString, "⌘U")
        XCTAssertEqual(ShortcutAction.openCorrections.defaultKeyBinding.displayString, "⌘K")
        XCTAssertEqual(ShortcutAction.openTroubleshooting.defaultKeyBinding.displayString, "⌘T")

        XCTAssertEqual(ShortcutAction.openSettings.defaultKeyBinding.displayString, "⌘1")
        XCTAssertEqual(ShortcutAction.openTranscriptionSettings.defaultKeyBinding.displayString, "⌘2")
        XCTAssertEqual(ShortcutAction.openPostProcessingSettings.defaultKeyBinding.displayString, "⌘3")
        XCTAssertEqual(ShortcutAction.openVoiceOutputSettings.defaultKeyBinding.displayString, "⌘4")
        XCTAssertEqual(ShortcutAction.openPronunciationSettings.defaultKeyBinding.displayString, "⌘5")
        XCTAssertEqual(ShortcutAction.openAPIKeysSettings.defaultKeyBinding.displayString, "⌘6")
        XCTAssertEqual(ShortcutAction.openKeyboardSettings.defaultKeyBinding.displayString, "⌘7")
        XCTAssertEqual(ShortcutAction.openPermissionsSettings.defaultKeyBinding.displayString, "⌘8")
        XCTAssertEqual(ShortcutAction.openCompareModelsSettings.defaultKeyBinding.displayString, "⌘9")
        XCTAssertEqual(ShortcutAction.openDataMigrationSettings.defaultKeyBinding.displayString, "⌘0")
        XCTAssertEqual(ShortcutAction.openAboutSettings.defaultKeyBinding.displayString, "⌘-")
        XCTAssertEqual(ShortcutAction.openProfilesSettings.defaultKeyBinding.displayString, "⌘+")

        XCTAssertEqual(ShortcutAction.quickVoice1.defaultKeyBinding.displayString, "⌥⌘1")
        XCTAssertEqual(ShortcutAction.quickVoice2.defaultKeyBinding.displayString, "⌥⌘2")
        XCTAssertEqual(ShortcutAction.quickVoice3.defaultKeyBinding.displayString, "⌥⌘3")
    }

    func testPasteLastHistoryItemDefault_isGlobalOptionCommandV() {
        let binding = ShortcutAction.pasteLastHistoryItem.defaultKeyBinding
        XCTAssertEqual(binding.displayString, "⌥⌘V")
        XCTAssertTrue(binding.isGlobal, "Paste Last History Item should be a global shortcut")
        XCTAssertTrue(binding.isEnabled, "Paste Last History Item should be enabled by default")
        XCTAssertTrue(ShortcutAction.pasteLastHistoryItem.isGlobalByDefault)
    }

    func testEverySettingsDestination_hasADistinctEnabledShortcut() throws {
        var bindings: [KeyBinding] = []
        for tab in SettingsTab.allCases {
            let action = try XCTUnwrap(SidebarItem.settings(tab).shortcutAction)
            let binding = action.defaultKeyBinding
            XCTAssertTrue(binding.isEnabled, "\(tab.title) needs a shortcut")
            XCTAssertFalse(binding.isGlobal)
            XCTAssertFalse(bindings.contains(binding), "\(tab.title) shares another settings shortcut")
            bindings.append(binding)
        }
    }

    func testEditSelectionByVoiceDefault_isGlobalOptionCommandE() {
        let binding = ShortcutAction.editSelectionByVoice.defaultKeyBinding
        XCTAssertEqual(binding.displayString, "⌥⌘E")
        XCTAssertTrue(binding.isGlobal, "Edit Selection by Voice should be a global shortcut")
        XCTAssertTrue(binding.isEnabled, "Edit Selection by Voice should be enabled by default")
        XCTAssertTrue(ShortcutAction.editSelectionByVoice.isGlobalByDefault)
    }

    func testPasteLastHistoryItemBinding_roundTripsThroughCodable() throws {
        let bindings: [ShortcutAction: KeyBinding] = [
            .pasteLastHistoryItem: ShortcutAction.pasteLastHistoryItem.defaultKeyBinding
        ]
        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: data)
        XCTAssertEqual(decoded[.pasteLastHistoryItem], ShortcutAction.pasteLastHistoryItem.defaultKeyBinding)
    }
}
