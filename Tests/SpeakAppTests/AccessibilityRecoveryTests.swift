import Combine
import Foundation
import XCTest

@testable import SpeakApp

@MainActor
final class AccessibilityRecoveryTests: XCTestCase {
    func testGrantHistory_survivesRestartAndClearsWarningWhenRestored() {
        let suite = "AccessibilityRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var status = PermissionStatus.denied
        let manager = PermissionsManager(
            statusProvider: { _ in status }, notificationCenter: NotificationCenter(), grantHistory: defaults
        )
        XCTAssertFalse(manager.accessibilityAccessWasLost)
        status = .granted
        manager.refresh(.accessibility)
        status = .denied
        let restarted = PermissionsManager(
            statusProvider: { _ in status }, notificationCenter: NotificationCenter(), grantHistory: defaults
        )
        XCTAssertTrue(restarted.accessibilityAccessWasLost)
        XCTAssertNotNil(restarted.accessibilityRecoveryMessage)
        status = .granted
        restarted.refresh(.accessibility)
        XCTAssertFalse(restarted.accessibilityAccessWasLost)
        XCTAssertNil(restarted.accessibilityRecoveryMessage)
    }

    func testRepeatedRefresh_doesNotPublishUnchangedPermissions() {
        let suite = "AccessibilityRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var status = PermissionStatus.denied
        let manager = PermissionsManager(
            statusProvider: { _ in status }, notificationCenter: NotificationCenter(), grantHistory: defaults
        )
        var changes = 0
        let observation = manager.objectWillChange.sink { changes += 1 }
        manager.refreshAll()
        manager.refreshAll()
        XCTAssertEqual(changes, 0)
        status = .granted
        manager.refresh(.accessibility)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }

    func testGrantHistory_isIsolatedBetweenAppPreferenceStores() {
        let firstSuite = "AccessibilityRecoveryTests.\(UUID().uuidString)"
        let secondSuite = "AccessibilityRecoveryTests.\(UUID().uuidString)"
        let first = UserDefaults(suiteName: firstSuite)!
        let second = UserDefaults(suiteName: secondSuite)!
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        _ = PermissionsManager(
            statusProvider: { _ in .granted }, notificationCenter: NotificationCenter(), grantHistory: first
        )
        let otherApp = PermissionsManager(
            statusProvider: { _ in .denied }, notificationCenter: NotificationCenter(), grantHistory: second
        )
        XCTAssertFalse(otherApp.accessibilityAccessWasLost)
    }
}
