import Foundation
import Security
import XCTest

@testable import SpeakCore

final class SecureStorageReconciliationTests: XCTestCase {
    @MainActor
    func testPreload_emptyKeychain_removesAllStaleTrackedProviderIdentifiers() async {
        let service = "com.justspeaktoit.tests.reconcile.empty.\(UUID().uuidString)"
        defer { deleteKeychainItem(service: service) }

        let registry = TestAPIKeyIdentifierRegistry(
            identifiers: [
                "deepgram.apiKey",
                "openrouter.apiKey",
                "assemblyai.apiKey"
            ]
        )
        let storage = SecureStorage(
            configuration: SecureStorageConfiguration(service: service),
            identifierRegistry: registry
        )

        let loaded = await storage.preloadAndReportSuccess()
        let knownIdentifiers = await storage.knownIdentifiers()

        XCTAssertTrue(loaded)
        XCTAssertEqual(knownIdentifiers, [])
        XCTAssertEqual(
            registry.trackedAPIKeyIdentifiers,
            [],
            "Persisted metadata must not claim absent Keychain credentials are stored"
        )
    }

    @MainActor
    func testPreload_replacesStaleMetadataWithAllCanonicalKeychainIdentifiers() async throws {
        let service = "com.justspeaktoit.tests.reconcile.subset.\(UUID().uuidString)"
        defer { deleteKeychainItem(service: service) }

        let seedStorage = SecureStorage(
            configuration: SecureStorageConfiguration(service: service)
        )
        try await seedStorage.storeSecret("openai-key", identifier: "openai.apiKey")
        try await seedStorage.storeSecret("assemblyai-key", identifier: "assemblyai.apiKey")

        let registry = TestAPIKeyIdentifierRegistry(
            identifiers: [
                "deepgram.apiKey",
                "openai.apiKey",
                "openrouter.apiKey"
            ]
        )
        let storage = SecureStorage(
            configuration: SecureStorageConfiguration(service: service),
            identifierRegistry: registry
        )

        let loaded = await storage.preloadAndReportSuccess()
        let knownIdentifiers = await storage.knownIdentifiers()

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            registry.trackedAPIKeyIdentifiers,
            ["assemblyai.apiKey", "openai.apiKey"]
        )
        XCTAssertEqual(
            knownIdentifiers,
            ["assemblyai.apiKey", "openai.apiKey"]
        )
    }

    @MainActor
    func testRemoveSecret_permissionFailure_preservesCacheAndTrackedMetadata() async throws {
        let service = "com.justspeaktoit.tests.reconcile.failed-removal.\(UUID().uuidString)"
        defer { deleteKeychainItem(service: service) }

        let seedStorage = SecureStorage(
            configuration: SecureStorageConfiguration(service: service)
        )
        try await seedStorage.storeSecret("deepgram-key", identifier: "deepgram.apiKey")

        let registry = TestAPIKeyIdentifierRegistry(identifiers: [])
        let permissions = SequencedKeychainPermissions(decisions: [true, false])
        let storage = SecureStorage(
            configuration: SecureStorageConfiguration(service: service),
            permissionsChecker: permissions,
            identifierRegistry: registry
        )
        let loaded = await storage.preloadAndReportSuccess()
        XCTAssertTrue(loaded)

        do {
            try await storage.removeSecret(identifier: "deepgram.apiKey")
            XCTFail("Removal should fail when Keychain permission is denied")
        } catch SecureStorageError.permissionDenied {
            // Expected.
        } catch {
            XCTFail("Unexpected removal error: \(error)")
        }

        let retainedSecret = try await storage.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(retainedSecret, "deepgram-key")
        XCTAssertEqual(registry.trackedAPIKeyIdentifiers, ["deepgram.apiKey"])
    }
}

@MainActor
private final class TestAPIKeyIdentifierRegistry: APIKeyIdentifierRegistry {
    private(set) var trackedAPIKeyIdentifiers: [String]

    init(identifiers: [String]) {
        trackedAPIKeyIdentifiers = identifiers
    }

    func registerAPIKeyIdentifier(_ identifier: String) {
        if !trackedAPIKeyIdentifiers.contains(identifier) {
            trackedAPIKeyIdentifiers.append(identifier)
        }
    }

    func removeAPIKeyIdentifier(_ identifier: String) {
        trackedAPIKeyIdentifiers.removeAll { $0 == identifier }
    }

    func reconcileAPIKeyIdentifiers(_ identifiers: [String]) {
        trackedAPIKeyIdentifiers = identifiers
    }
}

private actor SequencedKeychainPermissions: KeychainPermissionsChecking {
    private var decisions: [Bool]

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func ensureKeychainAccess(forService _: String) async -> Bool {
        decisions.isEmpty ? false : decisions.removeFirst()
    }
}

private func deleteKeychainItem(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "speak-app-secrets"
    ]
    SecItemDelete(query as CFDictionary)
}
