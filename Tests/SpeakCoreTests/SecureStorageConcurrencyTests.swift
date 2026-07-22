import Foundation
import XCTest

@testable import SpeakCore

final class SecureStorageConcurrencyTests: XCTestCase {
    func testConcurrentFirstReads_shareOneKeychainPermissionCheck() async {
        let permissions = DelayedKeychainPermissions()
        let storage = SecureStorage(
            configuration: SecureStorageConfiguration(
                service: "com.justspeaktoit.tests.\(UUID().uuidString)",
                masterAccount: "concurrent-load"
            ),
            permissionsChecker: permissions
        )

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<16 {
                group.addTask {
                    await storage.hasSecret(identifier: "missing-\(index)")
                }
            }

            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let permissionCheckCount = await permissions.checkCount
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { !$0 })
        XCTAssertEqual(
            permissionCheckCount,
            1,
            "Concurrent startup reads must coalesce before entering Security.framework"
        )
    }
}

private actor DelayedKeychainPermissions: KeychainPermissionsChecking {
    private(set) var checkCount = 0

    func ensureKeychainAccess(forService service: String) async -> Bool {
        checkCount += 1
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }
}
