import Foundation
import Security
import XCTest

@testable import SpeakCore

/// Round-trip behavior for the keychain-backed secret store: store, retrieve,
/// overwrite, delete, missing-key handling, payload encoding, and persistence
/// across storage instances. Each test uses a unique keychain service and
/// deletes it afterwards so runs never interfere with real credentials.
final class SecureStorageRoundTripTests: XCTestCase {
    private var service: String!

    override func setUp() {
        super.setUp()
        service = "com.justspeaktoit.tests.roundtrip.\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        deleteKeychainItem(service: service)
        service = nil
        super.tearDown()
    }

    private func makeStorage(
        permissionsChecker: any KeychainPermissionsChecking = DefaultKeychainPermissions()
    ) -> SecureStorage {
        SecureStorage(
            configuration: SecureStorageConfiguration(service: service),
            permissionsChecker: permissionsChecker
        )
    }

    // MARK: - Basic round trip

    func testStoreThenRetrieve_returnsStoredValue() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("sk-test-value", identifier: "openai.apiKey")

        let value = try await storage.secret(identifier: "openai.apiKey")
        XCTAssertEqual(value, "sk-test-value")

        let has = await storage.hasSecret(identifier: "openai.apiKey")
        XCTAssertTrue(has)
    }

    func testMissingIdentifier_throwsValueNotFound() async {
        let storage = makeStorage()
        do {
            _ = try await storage.secret(identifier: "never-stored")
            XCTFail("Expected valueNotFound")
        } catch SecureStorageError.valueNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let has = await storage.hasSecret(identifier: "never-stored")
        XCTAssertFalse(has)
    }

    func testOverwrite_replacesValueAndPersistsAcrossInstances() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("v1", identifier: "deepgram.apiKey")
        try await storage.storeSecret("v2", identifier: "deepgram.apiKey")

        let inMemory = try await storage.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(inMemory, "v2")

        // A fresh instance must read the overwritten value back from the Keychain.
        let reloaded = makeStorage()
        let persisted = try await reloaded.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(persisted, "v2")
    }

    func testRemove_thenRetrieve_throwsValueNotFound() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("value", identifier: "key.a")
        try await storage.removeSecret(identifier: "key.a")

        do {
            _ = try await storage.secret(identifier: "key.a")
            XCTFail("Expected valueNotFound after removal")
        } catch SecureStorageError.valueNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoveMissingIdentifier_doesNotThrow() async throws {
        let storage = makeStorage()
        // Removing something that was never stored is a no-op, not an error.
        try await storage.removeSecret(identifier: "never-stored")
    }

    func testRemovingLastSecret_clearsKeychainItemForFreshInstances() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("only-value", identifier: "only.key")
        try await storage.removeSecret(identifier: "only.key")

        let reloaded = makeStorage()
        let identifiers = await reloaded.knownIdentifiers()
        XCTAssertEqual(identifiers, [])
        let has = await reloaded.hasSecret(identifier: "only.key")
        XCTAssertFalse(has)
    }

    // MARK: - Multiple secrets and identifier listing

    func testMultipleSecrets_persistIndependentlyAndListSorted() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("value-b", identifier: "b.key")
        try await storage.storeSecret("value-a", identifier: "a.key")
        try await storage.storeSecret("value-c", identifier: "c.key")
        try await storage.removeSecret(identifier: "b.key")

        let reloaded = makeStorage()
        let identifiers = await reloaded.knownIdentifiers()
        XCTAssertEqual(identifiers, ["a.key", "c.key"])
        let valueA = try await reloaded.secret(identifier: "a.key")
        let valueC = try await reloaded.secret(identifier: "c.key")
        XCTAssertEqual(valueA, "value-a")
        XCTAssertEqual(valueC, "value-c")
    }

    func testWhitespaceOnlyValue_isNotReportedAsStored() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("   ", identifier: "blank.key")

        let has = await storage.hasSecret(identifier: "blank.key")
        XCTAssertFalse(has)
        let identifiers = await storage.knownIdentifiers()
        XCTAssertEqual(identifiers, [])
    }

    // MARK: - Payload encoding

    func testValueContainingEqualsSign_roundTripsThroughPayloadEncoding() async throws {
        // The aggregate payload is "key=value" pairs joined by ";".
        // Values containing "=" must survive the maxSplits:1 parse.
        let tricky = "abc=def==ghi"
        let storage = makeStorage()
        try await storage.storeSecret(tricky, identifier: "equals.key")

        let reloaded = makeStorage()
        let value = try await reloaded.secret(identifier: "equals.key")
        XCTAssertEqual(value, tricky)
    }

    func testUnicodeValue_roundTripsThroughPayloadEncoding() async throws {
        let unicode = "clé-secrète-\u{1F510}-鍵"
        let storage = makeStorage()
        try await storage.storeSecret(unicode, identifier: "unicode.key")

        let reloaded = makeStorage()
        let value = try await reloaded.secret(identifier: "unicode.key")
        XCTAssertEqual(value, unicode)
    }

    // MARK: - Permission-denied store leaves state untouched

    func testStoreDeniedByPermissions_throwsAndPreservesExistingSecret() async throws {
        let seed = makeStorage()
        try await seed.storeSecret("original", identifier: "guarded.key")

        // First decision (true) lets the cache load; second (false) denies the store.
        let permissions = ScriptedKeychainPermissions(decisions: [true, false])
        let storage = makeStorage(permissionsChecker: permissions)
        let loaded = await storage.preloadAndReportSuccess()
        XCTAssertTrue(loaded)

        do {
            try await storage.storeSecret("attacker-value", identifier: "guarded.key")
            XCTFail("Expected permissionDenied")
        } catch SecureStorageError.permissionDenied {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let retained = try await storage.secret(identifier: "guarded.key")
        XCTAssertEqual(retained, "original")

        let reloaded = makeStorage()
        let persisted = try await reloaded.secret(identifier: "guarded.key")
        XCTAssertEqual(persisted, "original")
    }

    // MARK: - Change notifications

    func testStoreAndRemove_postChangeNotificationsWithOperation() async throws {
        let storage = makeStorage()

        var operations: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: SecureStorage.didChangeSecretNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard
                let identifier = notification.userInfo?[
                    SecureStorage.NotificationUserInfoKey.identifier
                ] as? String,
                identifier == "notify.key",
                let operation = notification.userInfo?[
                    SecureStorage.NotificationUserInfoKey.operation
                ] as? String
            else { return }
            operations.append(operation)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await storage.storeSecret("value", identifier: "notify.key")
        try await storage.removeSecret(identifier: "notify.key")

        XCTAssertEqual(operations, ["store", "remove"])
    }
}

private actor ScriptedKeychainPermissions: KeychainPermissionsChecking {
    private var decisions: [Bool]

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func ensureKeychainAccess(forService _: String) async -> Bool {
        decisions.isEmpty ? false : decisions.removeFirst()
    }
}

private func deleteKeychainItem(service: String) {
    for account in [
        "speak-app-secrets",
        "speak-app-secrets.v2",
        "speak-app-secrets.unsupported-backup"
    ] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
