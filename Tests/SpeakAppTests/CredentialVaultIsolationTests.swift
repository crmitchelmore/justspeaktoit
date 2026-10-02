import Security
import SpeakCore
import XCTest

@testable import SpeakApp

/// A test bootstrap must open a vault of its own. The user's vault copies its
/// pre-rename predecessor forward on first load and, on App Store builds, joins
/// encrypted API-key sync, so a test vault inheriting either could read, copy
/// or sync the developer's real keys.
///
/// `SecureStorage` only queries its configured service and legacy services, so
/// checking those names proves isolation without touching the Keychain. Tests
/// that load a vault refuse one naming a production service, use UUID-suffixed
/// synthetic services and remove their items. Settings and permissions come
/// from an owned WireUp test host.
final class CredentialVaultIsolationTests: XCTestCase {
    private let productionServices = Set(
        ["com.github.speakapp.credentials", "com.justspeaktoit.credentials"].map(ReleaseTrain.current.namespace)
    )

    @MainActor
    func testProductionBootstrap_keepsUserVaultLegacyImportAndKeySync() {
        let options = WireUp.BootstrapOptions.default
        let vault = options.credentialStorage

        XCTAssertEqual(vault.service, ReleaseTrain.current.namespace("com.github.speakapp.credentials"))
        XCTAssertEqual(vault.masterAccount, "speak-app-secrets")
        XCTAssertEqual(vault.legacyServices, [ReleaseTrain.current.namespace("com.justspeaktoit.credentials")])
        XCTAssertNil(vault.accessGroup)
        XCTAssertFalse(vault.synchronizable)
        XCTAssertEqual(vault.accessibility, .platformDefault)
        XCTAssertTrue(options.startsCredentialKeySync(on: .appStore))
        XCTAssertFalse(options.startsCredentialKeySync(on: .direct))
    }

    @MainActor
    func testWireUpTestOptions_openIsolatedVaultWithoutKeySync() throws {
        let options = makeWireUpTestOptions()
        let vault = options.credentialStorage
        let override = try XCTUnwrap(options.keychainServiceOverride)

        XCTAssertEqual(vault.service, ReleaseTrain.current.namespace(override))
        XCTAssertEqual(vault.legacyServices, [], "A test vault must never import the user's legacy vault")
        XCTAssertTrue(productionServices.isDisjoint(with: [vault.service] + vault.legacyServices))
        for channel in DistributionChannel.allCases {
            XCTAssertFalse(options.startsCredentialKeySync(on: channel), "\(channel) must not sync a test vault")
        }
    }

    @MainActor
    func testNamedTestVault_hasNoPredecessor() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        let permissions = host.makePermissions()
        let named = SecureAppStorage(
            permissionsManager: permissions, appSettings: settings,
            keychainService: "com.justspeaktoit.tests.named.\(UUID().uuidString)"
        )
        // Opening a vault is inert until a load, and neither vault is loaded here.
        let unnamed = SecureAppStorage(permissionsManager: permissions, appSettings: settings)

        XCTAssertEqual(named.configuration.legacyServices, [])
        XCTAssertTrue(productionServices.isDisjoint(with: [named.configuration.service]))
        XCTAssertEqual(unnamed.configuration.service, SecureAppStorage.productionConfiguration.service)
        XCTAssertEqual(unnamed.configuration.legacyServices, SecureAppStorage.productionConfiguration.legacyServices)
    }

    /// Bootstrap opens its vault through `WireUp.buildSecureStorage`, so this
    /// runs the startup preload on the exact vault an overridden bootstrap gets.
    @MainActor
    func testOverriddenBootstrapVault_preloadsOnlyItsSyntheticService() async throws {
        let service = "com.justspeaktoit.tests.bootstrap.\(UUID().uuidString.prefix(8))"
        let options = WireUp.BootstrapOptions(keychainServiceOverride: service)
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        let vault = WireUp.buildSecureStorage(
            options: options, settings: settings, permissions: host.makePermissions()
        )
        XCTAssertEqual(vault.configuration.service, options.credentialStorage.service)
        XCTAssertEqual(vault.configuration.legacyServices, options.credentialStorage.legacyServices)
        let names = [vault.configuration.service] + vault.configuration.legacyServices
        guard vault.configuration.legacyServices.isEmpty, productionServices.isDisjoint(with: names) else {
            return XCTFail("Refusing to load a vault that can reach the user's keys: \(names)")
        }

        addTeardownBlock { deleteSyntheticVaultItems(services: [service]) }
        try await SecureStorage(configuration: SecureStorageConfiguration(service: service))
            .storeSecret("synthetic-bootstrap-key", identifier: "synthetic.apiKey")
        let loaded = await vault.preloadTrackedSecrets()
        let identifiers = await vault.knownIdentifiers()
        let secret = try await vault.secret(identifier: "synthetic.apiKey")
        XCTAssertTrue(loaded)
        XCTAssertEqual(identifiers, ["synthetic.apiKey"])
        XCTAssertEqual(secret, "synthetic-bootstrap-key")
        XCTAssertEqual(settings.trackedAPIKeyIdentifiers, ["synthetic.apiKey"])

        deleteSyntheticVaultItems(services: [service])
        XCTAssertFalse(syntheticItemExists(service: service), "The test must leave no Keychain item behind")
    }

    /// The user's vault layout and startup preload, between synthetic services.
    @MainActor
    func testSyntheticPredecessor_isCopiedForwardAndRetained() async throws {
        // Short names: older CI Keychains do not reliably round-trip 67-72
        // character services across storage instances.
        let suffix = String(UUID().uuidString.prefix(8))
        let legacyService = "com.justspeaktoit.tests.legacy.\(suffix)"
        let vaultService = "com.github.speakapp.tests.vault.\(suffix)"
        addTeardownBlock { deleteSyntheticVaultItems(services: [legacyService, vaultService]) }
        try await SecureStorage(configuration: SecureStorageConfiguration(service: legacyService))
            .storeSecret("synthetic-legacy-key", identifier: "synthetic.apiKey")

        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        let vault = SecureAppStorage(
            permissionsManager: host.makePermissions(), appSettings: settings,
            configuration: SecureAppStorage.vaultConfiguration(service: vaultService, legacyServices: [legacyService])
        )
        let loaded = await vault.preloadTrackedSecrets()
        let migrated = try await vault.secret(identifier: "synthetic.apiKey")
        XCTAssertTrue(loaded)
        XCTAssertEqual(migrated, "synthetic-legacy-key")
        XCTAssertEqual(settings.trackedAPIKeyIdentifiers, ["synthetic.apiKey"])

        // Copied, not moved: fresh readers find the predecessor retained for
        // rollback and the copy persisted in the vault's own service.
        let retained = try await SecureStorage(configuration: SecureStorageConfiguration(service: legacyService))
            .secret(identifier: "synthetic.apiKey")
        let persisted = try await SecureStorage(configuration: SecureStorageConfiguration(service: vaultService))
            .secret(identifier: "synthetic.apiKey")
        XCTAssertEqual(retained, "synthetic-legacy-key")
        XCTAssertEqual(persisted, "synthetic-legacy-key")

        deleteSyntheticVaultItems(services: [legacyService, vaultService])
        XCTAssertFalse(syntheticItemExists(service: legacyService), "The test must leave no Keychain item behind")
        XCTAssertFalse(syntheticItemExists(service: vaultService), "The test must leave no Keychain item behind")
    }
}

/// Removes this test's items; refuses any service that is not synthetic.
private func deleteSyntheticVaultItems(services: [String]) {
    for service in services {
        precondition(service.contains(".tests."), "Only synthetic test services may be deleted")
        for account in ["speak-app-secrets", "speak-app-secrets.v2", "speak-app-secrets.unsupported-backup"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ReleaseTrain.current.namespace(service),
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// Whether any item remains under a synthetic service. Returns no attributes or data.
private func syntheticItemExists(service: String) -> Bool {
    precondition(service.contains(".tests."), "Only synthetic test services may be inspected")
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: ReleaseTrain.current.namespace(service),
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}
