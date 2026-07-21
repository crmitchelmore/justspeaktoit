import AppKit
import SpeakCore
import XCTest

@testable import SpeakApp

final class PermissionsManagerTests: XCTestCase {
    func testInputMonitoringStatus_listenGrantIsGranted() {
        XCTAssertEqual(
            PermissionsManager.inputMonitoringStatus(
                hasListenAccess: true,
                hasAccessibilityAccess: false
            ),
            .granted
        )
    }

    func testInputMonitoringStatus_accessibilityGrantIsEffectiveAccess() {
        XCTAssertEqual(
            PermissionsManager.inputMonitoringStatus(
                hasListenAccess: false,
                hasAccessibilityAccess: true
            ),
            .granted
        )
    }

    func testInputMonitoringStatus_noGrantIsDenied() {
        XCTAssertEqual(
            PermissionsManager.inputMonitoringStatus(
                hasListenAccess: false,
                hasAccessibilityAccess: false
            ),
            .denied
        )
    }

    func testAccessibilityPromptPolicy_directPromptsAndAppStoreDoesNot() {
        XCTAssertTrue(PermissionsManager.shouldPromptForAccessibility(channel: .direct))
        XCTAssertFalse(PermissionsManager.shouldPromptForAccessibility(channel: .appStore))
    }

    func testAvailablePermissions_appStoreOmitsAccessibility() {
        XCTAssertFalse(PermissionType.availablePermissions(for: .appStore).contains(.accessibility))
        XCTAssertTrue(PermissionType.availablePermissions(for: .appStore).contains(.inputMonitoring))
        XCTAssertTrue(PermissionType.availablePermissions(for: .direct).contains(.accessibility))
    }

    @MainActor
    func testDidBecomeActive_refreshesPermissionStatuses() async {
        let notificationCenter = NotificationCenter()
        var accessibilityGranted = false
        let manager = PermissionsManager(
            statusProvider: { permission in
                if permission == .accessibility, accessibilityGranted {
                    return .granted
                }
                return .denied
            },
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(manager.status(for: .accessibility), .denied)

        accessibilityGranted = true
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(manager.status(for: .accessibility), .granted)
    }
}
