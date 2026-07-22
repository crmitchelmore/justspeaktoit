import Foundation
import Security
import XCTest

@testable import SpeakCore

final class SecureStorageConcurrencyTests: XCTestCase {
    func testLegacyServicePayload_isCopiedToCanonicalService() async throws {
        // Keep synthetic services close to production lengths. Older CI macOS
        // Keychain implementations do not reliably round-trip the previous
        // 67-72 character service names across separate storage instances.
        let suffix = String(UUID().uuidString.prefix(8))
        let legacyService = "com.justspeaktoit.tests.legacy.\(suffix)"
        let canonicalService = "com.github.speakapp.tests.canonical.\(suffix)"
        defer {
            deleteKeychainItem(service: legacyService, account: "speak-app-secrets")
            deleteKeychainItem(service: canonicalService, account: "speak-app-secrets")
        }

        let legacyStorage = SecureStorage(
            configuration: SecureStorageConfiguration(service: legacyService)
        )
        try await legacyStorage.storeSecret("preserved-key", identifier: "openai")

        let canonicalStorage = SecureStorage(
            configuration: SecureStorageConfiguration(
                service: canonicalService,
                legacyServices: [legacyService]
            )
        )

        let migratedValue = try await canonicalStorage.secret(identifier: "openai")
        XCTAssertEqual(migratedValue, "preserved-key")

        let canonicalReload = SecureStorage(
            configuration: SecureStorageConfiguration(service: canonicalService)
        )
        let persistedValue = try await canonicalReload.secret(identifier: "openai")
        XCTAssertEqual(persistedValue, "preserved-key")
    }

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

private func deleteKeychainItem(service: String, account: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
}

private actor DelayedKeychainPermissions: KeychainPermissionsChecking {
    private(set) var checkCount = 0

    func ensureKeychainAccess(forService service: String) async -> Bool {
        checkCount += 1
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }
}
