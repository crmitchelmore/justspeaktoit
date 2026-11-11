import CloudKit
import CryptoKit
import Foundation
import Security
import SpeakCore

/// The CloudKit side of key sync: zone and subscription setup, record reads and
/// writes, the change-token feed and the passphrase metadata record. Injected
/// dependencies replace each live CloudKit call in tests.
@MainActor
struct KeySyncCloudOperations {
    static let subscriptionCreatedKey = "speak.keysync.subscriptionCreated"
    static let zoneCreatedKey = "speak.keysync.zoneCreated"
    private static let subscriptionID = SyncSchema.EncryptedSecret.subscriptionID

    let dependencies: CloudKitKeySyncDependencies
    private let log = SpeakLogger.logger(category: "CloudKitKeySync")

    init(dependencies: CloudKitKeySyncDependencies) {
        self.dependencies = dependencies
    }

    func setupInfrastructure(database: CloudKitKeySyncDatabase) async throws {
        if let setupInfrastructure = dependencies.setupInfrastructure {
            try await setupInfrastructure(database)
            return
        }
        guard let liveDatabase = database.live else {
            throw CloudKitKeySyncError.cloudUnavailable
        }

        if !dependencies.defaults.bool(forKey: Self.zoneCreatedKey) {
            do {
                _ = try await liveDatabase.save(SyncConfiguration.recordZone)
                dependencies.defaults.set(true, forKey: Self.zoneCreatedKey)
            } catch let error as CKError where error.code == .serverRecordChanged {
                dependencies.defaults.set(true, forKey: Self.zoneCreatedKey)
            }
        }

        if !dependencies.defaults.bool(forKey: Self.subscriptionCreatedKey) {
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            do {
                _ = try await liveDatabase.save(subscription)
                dependencies.defaults.set(true, forKey: Self.subscriptionCreatedKey)
            } catch let error as CKError where error.code == .serverRejectedRequest {
                log.warning("Key sync subscription unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Derives the key from `passphrase` against the account's metadata record,
    /// creating that record (new salt and verifier) when none exists yet.
    func loadOrCreateMetadataKey(
        passphrase: String,
        database: CloudKitKeySyncDatabase
    ) async throws -> SymmetricKey {
        if let record = try await fetchRecord(id: KeySyncMetadataRecordMapper.recordID, database: database) {
            guard let metadata = KeySyncMetadataRecordMapper.metadata(from: record) else {
                throw CloudKitKeySyncError.malformedRecord
            }
            let key = await EncryptedSecretCrypto.deriveKeyOffMainActor(
                passphrase: passphrase,
                salt: metadata.salt
            )
            guard EncryptedSecretCrypto.verifyToken(
                nonce: metadata.verifierNonce,
                ciphertext: metadata.verifierCiphertext,
                tag: metadata.verifierTag,
                key: key
            ) else {
                throw CloudKitKeySyncError.incorrectPassphrase
            }
            return key
        }

        let salt = try Self.randomData(byteCount: EncryptedSecretEnvelope.saltByteCount)
        let key = await EncryptedSecretCrypto.deriveKeyOffMainActor(passphrase: passphrase, salt: salt)
        let token = try EncryptedSecretCrypto.makeVerificationToken(key: key)
        let metadata = KeySyncMetadata(
            salt: salt,
            verifierNonce: token.nonce,
            verifierCiphertext: token.ciphertext,
            verifierTag: token.tag
        )
        _ = try await saveRecord(
            KeySyncMetadataRecordMapper.record(from: metadata, updatedAt: dependencies.now()),
            database: database
        )
        return key
    }

    func fetchRecord(
        id: CKRecord.ID,
        database: CloudKitKeySyncDatabase
    ) async throws -> CKRecord? {
        if let fetchRecord = dependencies.fetchRecord {
            return try await fetchRecord(id, database)
        }
        guard let liveDatabase = database.live else {
            throw CloudKitKeySyncError.cloudUnavailable
        }
        do {
            return try await liveDatabase.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func saveRecord(
        _ record: CKRecord,
        database: CloudKitKeySyncDatabase
    ) async throws -> CKRecord {
        if let saveRecord = dependencies.saveRecord {
            return try await saveRecord(record, database)
        }
        guard let liveDatabase = database.live else {
            throw CloudKitKeySyncError.cloudUnavailable
        }
        return try await liveDatabase.save(record)
    }

    func executeFetchOperation(
        database: CloudKitKeySyncDatabase,
        changeToken: Data?
    ) async throws -> KeySyncFetchResult {
        if let fetchChanges = dependencies.fetchChanges {
            return try await fetchChanges(database, changeToken)
        }
        let accumulator = KeySyncFetchAccumulator()
        let operation = try makeFetchOperation(
            database: database,
            changeToken: changeToken,
            accumulator: accumulator
        )
        try await CloudKitKeySync.awaitFetchCompletion(of: operation)
        return try accumulator.result()
    }

    func loadChangeToken() -> Data? {
        dependencies.defaults.data(forKey: CloudKitKeySync.syncTokenKey)
    }

    func saveChangeToken(_ token: Data) {
        dependencies.defaults.set(token, forKey: CloudKitKeySync.syncTokenKey)
    }

    func clearChangeToken() {
        dependencies.defaults.removeObject(forKey: CloudKitKeySync.syncTokenKey)
    }

    static func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .changeTokenExpired {
            return true
        }
        return cloudError.partialErrorsByItemID?.values.contains {
            isChangeTokenExpired($0)
        } == true
    }

    private func makeFetchOperation(
        database: CloudKitKeySyncDatabase,
        changeToken: Data?,
        accumulator: KeySyncFetchAccumulator
    ) throws -> any KeySyncFetchOperationRunning {
        if let makeFetchOperation = dependencies.makeFetchOperation {
            return makeFetchOperation(database, changeToken)
        }
        guard let liveDatabase = database.live else {
            throw CloudKitKeySyncError.cloudUnavailable
        }
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        if let changeToken {
            do {
                config.previousServerChangeToken = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: CKServerChangeToken.self,
                    from: changeToken
                )
            } catch {
                log.error("Discarding unreadable CloudKit change token: \(error.localizedDescription)")
                clearChangeToken()
            }
        }
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncConfiguration.zoneID],
            configurationsByRecordZoneID: [SyncConfiguration.zoneID: config]
        )
        operation.fetchAllChanges = true
        Self.route(operation, into: accumulator)
        return LiveKeySyncFetchOperation(operation: operation, database: liveDatabase)
    }

    private static func route(
        _ operation: CKFetchRecordZoneChangesOperation,
        into accumulator: KeySyncFetchAccumulator
    ) {
        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record) where record.recordType == EncryptedSecretRecordMapper.recordType:
                accumulator.append(record: record)
            case .success:
                break
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            accumulator.appendDeletedID(recordID)
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            accumulator.updateToken(token)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (token, _, moreComing)):
                accumulator.updateToken(token)
                accumulator.updateMoreComing(moreComing)
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
    }

    private static func randomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CloudKitKeySyncError.randomGenerationFailed
        }
        return Data(bytes)
    }
}
