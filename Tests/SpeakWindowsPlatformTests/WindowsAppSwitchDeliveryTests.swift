#if os(Windows)
import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import XCTest

final class WindowsAppSwitchDeliveryTests: XCTestCase {
    func testOldInitializerReferenceAndMissingPolicyPreserveLegacyFlags() throws {
        let old: (WindowsTextOutputOptions.Method, WindowsTextOutputOptions.Insertion, Bool) -> WindowsTextOutputOptions
            = WindowsTextOutputOptions.init
        let options = try JSONDecoder().decode(WindowsTextOutputOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, old(.smart, .insertAtCursor, true))
        XCTAssertNil(options.appSwitchDelivery)
        XCTAssertEqual(options.nativeFlags, 0)
    }

    func testEveryPolicyPersistsAndAddsOnlyItsOwnFlag() throws {
        let policies: [(AppSwitchDelivery, UInt32)] = [
            (.originalApp, UInt32(JSTI_INSERTION_ORIGINAL_APP.rawValue)),
            (.currentApp, UInt32(JSTI_INSERTION_CURRENT_APP.rawValue)),
            (.onlyIfOriginalAppInFront, UInt32(JSTI_INSERTION_ONLY_ORIGINAL_FRONT.rawValue))
        ]
        for (policy, flag) in policies {
            // swiftlint:disable:next line_length
            var options = WindowsTextOutputOptions(method: .directOnly, insertion: .replaceField, restoreClipboard: false)
            let legacyFlags = options.nativeFlags
            options.appSwitchDelivery = policy
            let decoded = try JSONDecoder().decode(WindowsTextOutputOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded, options)
            XCTAssertEqual(decoded.nativeFlags, legacyFlags | flag)
        }
    }

    func testClipboardRecoveryNeverAcknowledgesInsertionOrAutomaticResume() {
        for verified in [false, true] {
            let outcome = WindowsInsertionTarget.Outcome(
                method: .clipboard, verified: verified, fieldIdentity: true, clipboard: .transcriptLeft
            )
            let result = WindowsInsertionStatus.delivery(for: outcome)
            XCTAssertEqual(result.disposition, .recoveryCopy)
            XCTAssertFalse(result.permitsAutomaticResume)
            XCTAssertTrue(result.status.contains("did not insert"))
        }
    }

    func testNativeCatalogueConfigurationRetainsSelectionAfterInvalidInput() {
        XCTAssertEqual(jsti_window_set_app_switch(
            AppSwitchDelivery.settingName, AppSwitchDelivery.desktopLabels, 2,
            AppSwitchDelivery.nativeHelp(canTargetApps: true)
        ), 0)
        XCTAssertEqual(jsti_window_app_switch_selection(), 2)
        XCTAssertEqual(jsti_window_set_app_switch("Policy", "one", 2, "help"), -1)
        XCTAssertEqual(jsti_window_app_switch_selection(), 2)
        XCTAssertEqual(jsti_window_set_app_switch("Policy", "one\n\nthree", 0, "help"), -1)
        XCTAssertEqual(jsti_window_app_switch_selection(), 2)
        jsti_window_clear_text_output()
    }
}
#endif
