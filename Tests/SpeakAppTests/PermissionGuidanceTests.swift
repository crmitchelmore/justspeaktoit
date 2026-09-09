import Foundation
import XCTest

@testable import SpeakApp

@MainActor
final class PermissionGuidanceTests: XCTestCase {
    func testGrantedPermission_doesNotOpenGuideOrRequestAgain() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .granted },
            speechAuthorizationRequester: { _ in XCTFail("Must not re-request a grant") },
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        let result = await manager.requestWithGuidance(.speechRecognition)
        XCTAssertEqual(result, .granted)
        XCTAssertTrue(opened.isEmpty)
    }

    func testDeniedPromptPermissions_openRecoveryWithoutReprompting() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .denied },
            speechAuthorizationRequester: { _ in XCTFail("Denied permission cannot re-prompt") },
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        for permission in [PermissionType.microphone, .speechRecognition] {
            let result = await manager.requestWithGuidance(permission)
            XCTAssertEqual(result, .denied)
        }
        XCTAssertEqual(opened, [.microphone, .speechRecognition])
    }

    func testFirstSpeechRequest_usesSystemPromptAndOpensGuideOnlyOnDenial() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .notDetermined },
            speechAuthorizationRequester: { callback in callback(.denied) },
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        let result = await manager.requestWithGuidance(.speechRecognition)
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(opened, [.speechRecognition])
    }

    func testTimedOutSpeechRequest_opensRecovery() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .notDetermined },
            speechAuthorizationRequester: { _ in },
            speechAuthorizationTimeout: 0.01,
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        _ = await manager.requestWithGuidance(.speechRecognition)
        XCTAssertEqual(manager.requestIssue(for: .speechRecognition), .timedOut)
        XCTAssertEqual(opened, [.speechRecognition])
    }

    func testBackgroundChecks_doNotOpenSettingsForDeniedPermission() async {
        let manager = PermissionsManager(
            statusProvider: { _ in .denied },
            notificationCenter: NotificationCenter(),
            guidePresenter: { _ in XCTFail("Background checks must not open Settings") }
        )
        let result = await manager.ensureGranted(.microphone)
        XCTAssertEqual(result, .denied)
    }

    func testRestrictedPermission_showsAdministrativeRecovery() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .restricted },
            speechAuthorizationRequester: { _ in XCTFail("Restricted permission cannot prompt") },
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        _ = await manager.requestWithGuidance(.speechRecognition)
        XCTAssertEqual(opened, [.speechRecognition])
        XCTAssertTrue(PermissionType.speechRecognition.settingsInstructions(appName: "Speak", status: .restricted)
            .contains("administrator"))
    }

    func testOnlyManuallyAddablePermissions_offerDragGuidance() {
        XCTAssertNotNil(PermissionType.accessibility.dragGuidancePane)
        XCTAssertNotNil(PermissionType.inputMonitoring.dragGuidancePane)
        XCTAssertNil(PermissionType.microphone.dragGuidancePane)
        XCTAssertNil(PermissionType.speechRecognition.dragGuidancePane)
    }
}
