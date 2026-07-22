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
    func testSpeechRecognitionRequest_completedCallbackReturnsMappedStatus() async {
        let manager = PermissionsManager(
            statusProvider: { _ in .notDetermined },
            speechAuthorizationRequester: { callback in callback(.authorized) },
            speechAuthorizationTimeout: 0.05,
            notificationCenter: NotificationCenter()
        )

        let result = await manager.request(.speechRecognition)

        XCTAssertEqual(result, .granted)
        XCTAssertNil(manager.requestIssue(for: .speechRecognition))
    }

    @MainActor
    func testSpeechRecognitionRequest_missingCallbackTimesOutWithGuidance() async {
        let manager = PermissionsManager(
            statusProvider: { _ in .notDetermined },
            speechAuthorizationRequester: { _ in },
            speechAuthorizationTimeout: 0.01,
            notificationCenter: NotificationCenter()
        )

        let result = await manager.request(.speechRecognition)

        XCTAssertEqual(result, .notDetermined)
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)
        XCTAssertTrue(
            PermissionRequestIssue.timedOut
                .guidance(for: .speechRecognition)
                .contains("Open System Settings")
        )
    }

    @MainActor
    func testSpeechRecognitionRequest_lateCallbackAfterTimeoutIsIgnored() async {
        let manager = PermissionsManager(
            statusProvider: { _ in .notDetermined },
            speechAuthorizationRequester: { callback in
                Task {
                    try? await Task.sleep(for: .seconds(0.05))
                    callback(.authorized)
                }
            },
            speechAuthorizationTimeout: 0.01,
            notificationCenter: NotificationCenter()
        )

        let result = await manager.request(.speechRecognition)

        XCTAssertEqual(result, .notDetermined)
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)
    }

    @MainActor
    func testRefresh_clearsTimedOutIssueAfterSystemStatusChanges() async {
        var systemStatus = PermissionStatus.notDetermined
        let manager = PermissionsManager(
            statusProvider: { _ in systemStatus },
            speechAuthorizationRequester: { _ in },
            speechAuthorizationTimeout: 0.01,
            notificationCenter: NotificationCenter()
        )
        _ = await manager.request(.speechRecognition)
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)

        systemStatus = .granted
        manager.refresh(.speechRecognition)

        XCTAssertEqual(manager.status(for: .speechRecognition), .granted)
        XCTAssertNil(manager.requestIssue(for: .speechRecognition))
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
