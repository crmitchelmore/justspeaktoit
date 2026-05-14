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
}
