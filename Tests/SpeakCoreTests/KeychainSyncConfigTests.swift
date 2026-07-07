import XCTest

@testable import SpeakCore

final class KeychainSyncConfigTests: XCTestCase {

    func testICloudSyncedConfig_preservesServiceAndAccount() {
        // Act
        let config = SecureStorageConfiguration.iCloudSyncedIfAvailable(
            service: "com.example.credentials",
            masterAccount: "secrets",
            accessGroup: "group.example"
        )

        // Assert
        XCTAssertEqual(config.service, "com.example.credentials")
        XCTAssertEqual(config.masterAccount, "secrets")
    }

    func testICloudSyncedConfig_keepsAccessGroupOnlyWhenSynchronizable() {
        // Act
        let config = SecureStorageConfiguration.iCloudSyncedIfAvailable(
            service: "com.example.credentials",
            accessGroup: "group.example"
        )

        // Assert: an access group is retained only when sync is actually enabled,
        // so a build without the entitlement never writes to an inaccessible group.
        if config.synchronizable {
            XCTAssertEqual(config.accessGroup, "group.example")
        } else {
            XCTAssertNil(config.accessGroup)
        }
    }

    func testAvailabilityProbe_returnsWithoutThrowing() {
        // The result depends on the host's entitlements; we only assert the
        // probe completes and returns a Bool rather than crashing.
        _ = KeychainSyncAvailability.isAvailable()
        _ = KeychainSyncAvailability.isAvailable(accessGroup: "group.example")
    }
}
