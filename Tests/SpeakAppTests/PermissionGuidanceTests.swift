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

    func testInputMonitoringGrant_opensGuideEvenWithoutANativeDialog() async {
        var opened: [PermissionType] = []
        let manager = PermissionsManager(
            statusProvider: { _ in .denied },
            notificationCenter: NotificationCenter(),
            guidePresenter: { opened.append($0) }
        )
        // This must not call CGRequestListenEventAccess or depend on the test
        // runner's real TCC grants; every denied click has a visible outcome.
        for _ in 0..<2 {
            let result = await manager.requestWithGuidance(.inputMonitoring)
            XCTAssertEqual(result, .denied)
        }
        XCTAssertEqual(opened, [.inputMonitoring, .inputMonitoring])
    }

    func testRunningAppIdentity_preservesAlphaAndDevelopmentNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for filename in ["Just Speak to It Alpha.app", "JustSpeakToItDev.app", "Renamed Copy.app"] {
            let appURL = directory.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let identity = RunningAppIdentity(bundleURL: appURL)
            XCTAssertEqual(identity.bundleURL, appURL)
            XCTAssertTrue(identity.name.contains(appURL.deletingPathExtension().lastPathComponent))
            XCTAssertTrue(identity.recoveryInstructions.contains(identity.name))
            for permission in PermissionType.allCases {
                XCTAssertTrue(permission.settingsInstructions(appName: identity.name, status: .denied)
                    .contains(identity.name))
            }
        }
    }

    func testRestrictedAndReducedMotionPermissions_useNativeExplanations() {
        for permission in [PermissionType.accessibility, .inputMonitoring] {
            XCTAssertFalse(permission.usesDragGuide(status: .restricted, reduceMotion: false))
            XCTAssertFalse(permission.usesDragGuide(status: .denied, reduceMotion: true))
            XCTAssertTrue(permission.usesDragGuide(status: .denied, reduceMotion: false))
        }
    }

    func testDeniedSwitchPermissions_doNotPromiseAnotherPrompt() {
        for permission in [PermissionType.microphone, .speechRecognition] {
            XCTAssertFalse(permission.settingsInstructions(appName: "Alpha", status: .denied)
                .contains("choose Request"))
            XCTAssertTrue(permission.settingsInstructions(appName: "Alpha", status: .notDetermined)
                .contains("choose Request"))
        }
    }

    func testOnlyManuallyAddablePermissions_offerDragGuidance() {
        XCTAssertNotNil(PermissionType.accessibility.dragGuidancePane)
        XCTAssertNotNil(PermissionType.inputMonitoring.dragGuidancePane)
        XCTAssertNil(PermissionType.microphone.dragGuidancePane)
        XCTAssertNil(PermissionType.speechRecognition.dragGuidancePane)
    }
}
