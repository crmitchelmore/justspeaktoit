import CloudKit
import CryptoKit
import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

/// The one-time API-key sync carry-over from the legacy CloudKit container (#1119).
@MainActor
final class CloudKitKeySyncLegacyContainerTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    private let salt = Data("legacy-salt".utf8)

    func testSameAccount_carriesPassphraseAndKeysIntoTheSharedContainer() async throws {
        let harness = makeHarness()
        harness.cloud.store(try metadataRecord(key: key), in: .legacy)
        harness.cloud.legacyChanges = [try secretRecord("openai.apiKey", value: "from-legacy")]
        await harness.secrets.set("local", identifier: "deepgram.apiKey")

        try await harness.sync.syncNow()

        let defaults = harness.defaults
        XCTAssertTrue(defaults.bool(forKey: CloudKitKeySync.enabledKey), "key sync stays on")
        XCTAssertEqual(defaults.string(forKey: CloudKitKeySync.accountIdentifierKey), fingerprint("shared-account"))
        XCTAssertNil(defaults.object(forKey: CloudKitKeySync.legacyAccountIdentifierKey))
        XCTAssertFalse(defaults.bool(forKey: CloudKitKeySync.legacyContainerCopyPendingKey))

        let sharedMetadata = try XCTUnwrap(harness.cloud.metadata(in: .shared))
        XCTAssertEqual(sharedMetadata.salt, salt, "the same passphrase derives the same key")
        XCTAssertTrue(EncryptedSecretCrypto.verifyToken(
            nonce: sharedMetadata.verifierNonce,
            ciphertext: sharedMetadata.verifierCiphertext,
            tag: sharedMetadata.verifierTag,
            key: key
        ))
        let fromLegacy = try await harness.secrets.secret(identifier: "openai.apiKey")
        XCTAssertEqual(fromLegacy, "from-legacy")
        let uploaded = Set(harness.cloud.savedSecretIdentifiers(in: .shared))
        XCTAssertEqual(
            uploaded, ["openai.apiKey", "deepgram.apiKey"], "every key is re-encrypted into the shared container"
        )
        XCTAssertTrue(harness.cloud.savedSecretIdentifiers(in: .legacy).isEmpty, "the legacy container is only read")
        XCTAssertEqual(harness.cloud.fetchTokens[.legacy], [nil])
        XCTAssertEqual(harness.cloud.fetchTokens[.shared]?.first, .some(nil), "the shared feed starts from scratch")
    }

    func testDifferentLegacyAccount_isAnAccountChangeAndResetsKeySync() async throws {
        let harness = makeHarness(legacyFingerprint: fingerprint("someone-else"))

        let available = await harness.sync.isAvailable()
        XCTAssertTrue(available)

        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.legacyContainerCopyPendingKey))
        XCTAssertNil(harness.defaults.object(forKey: CloudKitKeySync.legacyAccountIdentifierKey))
    }

    func testLegacyAccountLookupFailure_wipesNothingAndRetries() async throws {
        let harness = makeHarness()
        harness.cloud.legacyAccountError = CKError(.networkUnavailable)

        let available = await harness.sync.isAvailable()
        XCTAssertFalse(available)

        XCTAssertTrue(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertNil(harness.defaults.object(forKey: CloudKitKeySync.accountIdentifierKey))
        XCTAssertEqual(
            harness.defaults.string(forKey: CloudKitKeySync.legacyAccountIdentifierKey), fingerprint("legacy-account")
        )
    }

    func testSharedContainerUsesAnotherPassphrase_turnsKeySyncOffToAskForIt() async throws {
        let harness = makeHarness()
        harness.cloud.store(try metadataRecord(key: key), in: .legacy)
        harness.cloud.store(try metadataRecord(key: SymmetricKey(data: Data(repeating: 9, count: 32))), in: .shared)

        do {
            try await harness.sync.syncNow()
            XCTFail("Expected missingPassphrase")
        } catch CloudKitKeySyncError.missingPassphrase {
            // Expected.
        }

        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertFalse(harness.sync.status.isEnabled)
        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.legacyContainerCopyPendingKey))
        XCTAssertTrue(harness.cloud.savedSecretIdentifiers(in: .shared).isEmpty)
    }

    // MARK: - Helpers

    private struct Harness {
        let sync: CloudKitKeySync
        let secrets: LegacyTestSecretStorage
        let defaults: UserDefaults
        let cloud: TwoContainerCloud
    }

    /// A device whose fingerprint `SyncContainerTransition` set aside after
    /// moving from the legacy container.
    private func makeHarness(legacyFingerprint: String? = nil) -> Harness {
        let suiteName = "CloudKitKeySyncLegacyContainerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: CloudKitKeySync.enabledKey)
        defaults.set(
            legacyFingerprint ?? fingerprint("legacy-account"), forKey: CloudKitKeySync.legacyAccountIdentifierKey
        )
        let cloud = TwoContainerCloud()
        let secrets = LegacyTestSecretStorage()
        let dependencies = CloudKitKeySyncDependencies(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_720_199_999) },
            sleep: { _ in },
            hasCloudKitEntitlement: { true },
            privateDatabase: { TwoContainerCloud.Container.shared.database },
            accountStatus: { .available },
            accountRecordName: { "shared-account" },
            setupInfrastructure: { _ in },
            fetchRecord: { id, database in cloud.records[.init(database)]?[id.recordName] },
            saveRecord: { record, database in cloud.save(record, in: .init(database)) },
            fetchChanges: { database, token in try cloud.fetch(.init(database), token: token) },
            makeFetchOperation: nil,
            legacyDatabase: { TwoContainerCloud.Container.legacy.database },
            legacyAccountRecordName: {
                if let error = cloud.legacyAccountError { throw error }
                return "legacy-account"
            }
        )
        let sync = CloudKitKeySync(
            secureStorage: secrets,
            stateStorage: LegacyTestSecretStorage(),
            dependencies: dependencies,
            isConfigured: true,
            symmetricKey: key
        )
        return Harness(sync: sync, secrets: secrets, defaults: defaults, cloud: cloud)
    }

    private func metadataRecord(key: SymmetricKey) throws -> CKRecord {
        let token = try EncryptedSecretCrypto.makeVerificationToken(key: key)
        return KeySyncMetadataRecordMapper.record(
            from: KeySyncMetadata(
                salt: salt, verifierNonce: token.nonce, verifierCiphertext: token.ciphertext, verifierTag: token.tag
            ),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func secretRecord(_ identifier: String, value: String) throws -> CKRecord {
        EncryptedSecretRecordMapper.record(from: try EncryptedSecretCrypto.encryptSecret(
            identifier: identifier, value: value, updatedAt: Date(timeIntervalSince1970: 100), key: key
        ))
    }
}

@MainActor
private final class TwoContainerCloud {
    enum Container: String {
        case shared
        case legacy

        init(_ database: CloudKitKeySyncDatabase) {
            self = Container(rawValue: database.container ?? "") ?? .shared
        }

        var database: CloudKitKeySyncDatabase {
            CloudKitKeySyncDatabase(live: nil, container: rawValue)
        }
    }

    var records: [Container: [String: CKRecord]] = [:]
    var saved: [Container: [CKRecord]] = [:]
    var legacyChanges: [CKRecord] = []
    var fetchTokens: [Container: [Data?]] = [:]
    var legacyAccountError: Error?

    func store(_ record: CKRecord, in container: Container) {
        records[container, default: [:]][record.recordID.recordName] = record
    }

    func save(_ record: CKRecord, in container: Container) -> CKRecord {
        saved[container, default: []].append(record)
        store(record, in: container)
        return record
    }

    func fetch(_ container: Container, token: Data?) throws -> KeySyncFetchResult {
        fetchTokens[container, default: []].append(token)
        return KeySyncFetchResult(
            records: container == .legacy && token == nil ? legacyChanges : [],
            deletedIDs: [],
            serverChangeTokenData: Data("\(container.rawValue)-token".utf8),
            moreComing: false
        )
    }

    func metadata(in container: Container) -> KeySyncMetadata? {
        records[container]?[SyncSchema.KeySyncMetadata.recordName].flatMap(KeySyncMetadataRecordMapper.metadata(from:))
    }

    func savedSecretIdentifiers(in container: Container) -> [String] {
        (saved[container] ?? []).compactMap { EncryptedSecretRecordMapper.secret(from: $0)?.identifier }
    }
}

private actor LegacyTestSecretStorage: CloudKitKeySyncSecretStoring {
    private var values: [String: String] = [:]

    func set(_ value: String, identifier: String) {
        values[identifier] = value
    }

    func storeSecret(_ value: String, identifier: String) async throws {
        values[identifier] = value
    }

    func secret(identifier: String) async throws -> String {
        guard let value = values[identifier] else { throw SecureStorageError.valueNotFound }
        return value
    }

    func removeSecret(identifier: String) async throws {
        values[identifier] = nil
    }
}

private func fingerprint(_ accountName: String) -> String {
    CloudKitKeySync.accountFingerprint(accountName)
}
