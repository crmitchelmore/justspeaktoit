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
            .openVoiceOutputSettings,
            .openPronunciationSettings,
            .openAPIKeysSettings,
            .openKeyboardSettings,
            .openPermissionsSettings,
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
        XCTAssertEqual(ShortcutAction.openAboutSettings.defaultKeyBinding.displayString, "⌘9")

        XCTAssertEqual(ShortcutAction.quickVoice1.defaultKeyBinding.displayString, "⌥⌘1")
        XCTAssertEqual(ShortcutAction.quickVoice2.defaultKeyBinding.displayString, "⌥⌘2")
        XCTAssertEqual(ShortcutAction.quickVoice3.defaultKeyBinding.displayString, "⌥⌘3")
    }
}
