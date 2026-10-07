#if os(iOS)
import Foundation
import Security
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// API-key edits must reach the Keychain, and come back from it, in the order
/// they were made, even when an earlier write is held up inside the store.
@MainActor
final class APIKeyPersistenceOrderingTests: XCTestCase {
    func testLaterEditWinsWhenAnEarlierWriteIsDelayed() async throws {
        let fixture = OrderingFixture()
        defer { fixture.cleanUp() }
        let permissions = GatedKeychainPermissions()
        let storage = fixture.storage(permissions: permissions)
        let preloaded = await storage.preloadAndReportSuccess()
        XCTAssertTrue(preloaded)
        let settings = fixture.settings(storage: storage)

        await permissions.holdNextCheck()
        settings.deepgramAPIKey = "first-key"
        await permissions.waitUntilHeld()
        settings.deepgramAPIKey = "second-key"
        // An unordered second write would overtake the held first one here.
        try await Task.sleep(for: .milliseconds(100))
        await permissions.release()
        await settings.awaitPendingSecretWrites()

        let stored = try await storage.secret(identifier: AppSettings.deepgramKeyID)
        XCTAssertEqual(stored, "second-key")
        XCTAssertEqual(settings.deepgramAPIKey, "second-key")
    }

    func testReloadKeepsALocalEditWhoseWriteIsStillPending() async throws {
        let fixture = OrderingFixture()
        defer { fixture.cleanUp() }
        let permissions = GatedKeychainPermissions()
        let storage = fixture.storage(permissions: permissions)
        try await storage.storeSecret("stored-key", identifier: AppSettings.deepgramKeyID)
        let settings = fixture.settings(storage: storage)
        let loaded = await settings.reloadSyncedAPIKeys()
        XCTAssertTrue(loaded)
        XCTAssertEqual(settings.deepgramAPIKey, "stored-key")

        await permissions.holdNextCheck()
        settings.deepgramAPIKey = "edited-key"
        await permissions.waitUntilHeld()
        let reloadedWhilePending = await settings.reloadSyncedAPIKeys()
        XCTAssertTrue(reloadedWhilePending)
        XCTAssertEqual(settings.deepgramAPIKey, "edited-key")

        await permissions.release()
        await settings.awaitPendingSecretWrites()
        let reloadedAfterWrite = await settings.reloadSyncedAPIKeys()
        XCTAssertTrue(reloadedAfterWrite)
        XCTAssertEqual(settings.deepgramAPIKey, "edited-key")
        let stored = try await storage.secret(identifier: AppSettings.deepgramKeyID)
        XCTAssertEqual(stored, "edited-key")
    }
}

@MainActor
private struct OrderingFixture {
    let service = "test.ordering.\(UUID().uuidString.prefix(8))"
    let suite = "APIKeyPersistenceOrderingTests.\(UUID().uuidString)"

    func storage(permissions: GatedKeychainPermissions) -> SecureStorage {
        SecureStorage(
            configuration: .init(service: service, accessibility: .afterFirstUnlock),
            permissionsChecker: permissions
        )
    }

    func settings(storage: SecureStorage) -> AppSettings {
        AppSettings(
            defaults: UserDefaults(suiteName: suite)!,
            loadsSecureStorage: false,
            credentialStorage: storage
        )
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }
}

/// Grants every Keychain access check, except that once armed it holds the
/// next check open until released, as a slow Keychain call would.
private actor GatedKeychainPermissions: KeychainPermissionsChecking {
    private var holdsNextCheck = false
    private var heldCheck: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextCheck() {
        self.holdsNextCheck = true
    }

    func ensureKeychainAccess(forService _: String) async -> Bool {
        guard self.holdsNextCheck else { return true }
        self.holdsNextCheck = false
        await withCheckedContinuation { continuation in
            self.heldCheck = continuation
            self.heldWaiters.forEach { $0.resume() }
            self.heldWaiters.removeAll()
        }
        return true
    }

    func waitUntilHeld() async {
        guard self.heldCheck == nil else { return }
        await withCheckedContinuation { continuation in
            self.heldWaiters.append(continuation)
        }
    }

    func release() {
        self.heldCheck?.resume()
        self.heldCheck = nil
    }
}
#endif
