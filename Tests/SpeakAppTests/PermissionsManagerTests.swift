import AppKit
import Combine
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
                    // Wide margin vs the 0.1s timeout: loaded CI runners can
                    // stall the process long enough for tighter sleeps to
                    // invert, letting the "late" callback beat the timeout.
                    try? await Task.sleep(for: .seconds(1.0))
                    callback(.authorized)
                }
            },
            speechAuthorizationTimeout: 0.1,
            notificationCenter: NotificationCenter()
        )

        let result = await manager.request(.speechRecognition)

        XCTAssertEqual(result, .notDetermined)
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)
        try? await Task.sleep(for: .seconds(1.2))
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

    /// The Permissions tab only re-renders when the manager publishes. A grant
    /// made in System Settings must therefore surface through `refreshAll()`
    /// as a published change, not just a silent dictionary write (issue #860).
    @MainActor
    func testRefreshAll_publishesWhenASystemStatusChanges() {
        var systemStatuses: [PermissionType: PermissionStatus] = [
            .microphone: .granted,
            .speechRecognition: .granted,
            .accessibility: .denied,
            .inputMonitoring: .granted
        ]
        let manager = PermissionsManager(
            statusProvider: { systemStatuses[$0] ?? .notDetermined },
            speechAuthorizationRequester: { $0(.authorized) }
        )
        XCTAssertEqual(manager.status(for: .accessibility), .denied)

        var publishCount = 0
        let subscription = manager.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        systemStatuses[.accessibility] = .granted
        manager.refreshAll()

        XCTAssertEqual(manager.status(for: .accessibility), .granted)
        XCTAssertGreaterThan(publishCount, 0, "refreshAll() must publish so observing views re-render")
    }
}
