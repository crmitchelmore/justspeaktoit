import CloudKit
import CryptoKit
import Foundation
import SpeakCore

/// Moves encrypted secrets between the local Keychain and CloudKit: applies
/// fetched changes, uploads pending local mutations and resolves which side is
/// newer. Every step takes the caller's `ensureActive` check, which throws
/// `CancellationError` once the sync generation that started it is stale.
@MainActor
final class KeySyncSecretTransfer {
    enum UploadResult: Equatable {
        case uploaded
        case superseded
    }

    var secureStorage: any CloudKitKeySyncSecretStoring
    var pending: KeySyncPendingMutations
    let localState: KeySyncLocalState
    let cloud: KeySyncCloudOperations
    /// Identifiers whose Keychain write comes from CloudKit, so the change
    /// notification it raises is not echoed back as a local edit.
    private(set) var applyingRemoteIdentifiers = Set<String>()
    private let log = SpeakLogger.logger(category: "CloudKitKeySync")

    init(
        secureStorage: any CloudKitKeySyncSecretStoring,
        localState: KeySyncLocalState,
        cloud: KeySyncCloudOperations
    ) {
        self.secureStorage = secureStorage
        self.localState = localState
        self.cloud = cloud
        self.pending = KeySyncPendingMutations(defaults: cloud.dependencies.defaults)
    }

    /// Records a pending update for every syncable key already stored locally.
    func seedPendingMutationsForExistingSecrets() async throws {
        var mutationsToPersist: [PendingKeySyncMutation] = []
        for identifier in CloudKitKeySync.syncableIdentifiers.sorted() where pending[identifier] == nil {
            do {
                _ = try await secureStorage.secret(identifier: identifier)
                mutationsToPersist.append(PendingKeySyncMutation(
                    operationID: UUID(),
                    identifier: identifier,
                    updatedAt: cloud.dependencies.now(),
                    kind: .update
                ))
            } catch SecureStorageError.valueNotFound {
                continue
            } catch {
                log.error("Could not inspect local encrypted secret \(identifier): \(error.localizedDescription)")
                throw error
            }
        }
        for mutation in mutationsToPersist {
            pending.record(mutation)
        }
    }

    /// Fetches and applies remote changes, restarting from scratch once if the
    /// stored change token has expired.
    func fetchRemoteChanges(
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        do {
            try await fetchAndApplyRemoteChanges(
                database: database, key: key, changeToken: cloud.loadChangeToken(), ensureActive: ensureActive
            )
        } catch {
            guard KeySyncCloudOperations.isChangeTokenExpired(error) else { throw error }
            cloud.clearChangeToken()
            try ensureActive()
            try await fetchAndApplyRemoteChanges(
                database: database, key: key, changeToken: nil, ensureActive: ensureActive
            )
        }
    }

    /// Uploads one batch of pending local mutations; the first failure is
    /// rethrown after the rest of the batch has been attempted.
    func uploadLocalSecrets(
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        var firstError: Error?
        let mutations = CloudKitKeySync.syncableIdentifiers
            .compactMap { pending.current($0) }
            .sorted { $0.identifier < $1.identifier }
            .prefix(SyncConfiguration.batchSize)

        for mutation in mutations {
            try ensureActive()
            do {
                try await upload(mutation, database: database, key: key, ensureActive: ensureActive)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                log.error(
                    "Could not upload local encrypted secret \(mutation.identifier): \(error.localizedDescription)"
                )
            }
        }

        if let firstError {
            throw firstError
        }
    }

    /// Uploads `mutation` and, once CloudKit holds it, records the upload and
    /// clears the mutation unless a newer local edit replaced it meanwhile.
    func upload(
        _ mutation: PendingKeySyncMutation,
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        let uploadResult = try await uploadSecret(mutation, database: database, key: key, ensureActive: ensureActive)
        if uploadResult == .uploaded {
            try await localState.saveUpdatedAt(mutation.updatedAt, identifier: mutation.identifier)
            pending.clear(ifMatching: mutation)
        }
    }

    private func fetchAndApplyRemoteChanges(
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        changeToken: Data?,
        ensureActive: () throws -> Void
    ) async throws {
        var nextChangeToken = changeToken
        while true {
            let result = try await cloud.executeFetchOperation(database: database, changeToken: nextChangeToken)
            try await applyFetchedChanges(result, key: key, ensureActive: ensureActive)
            guard result.moreComing else { return }
            guard let token = result.serverChangeTokenData else {
                throw CloudKitKeySyncError.invalidChangeToken
            }
            nextChangeToken = token
        }
    }

    private func applyFetchedChanges(
        _ result: KeySyncFetchResult,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        try ensureActive()
        let recordError = try await applyFetchedRecords(result.records, key: key, ensureActive: ensureActive)
        let deletionError = try await applyFetchedDeletions(result.deletedIDs, ensureActive: ensureActive)
        if let firstError = recordError ?? deletionError {
            throw firstError
        }
        try ensureActive()
        if let token = result.serverChangeTokenData {
            cloud.saveChangeToken(token)
        }
    }

    /// Applies every fetched secret record, returning the first failure.
    private func applyFetchedRecords(
        _ records: [CKRecord],
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws -> Error? {
        var firstError: Error?
        for record in records {
            try ensureActive()
            guard record.recordType == EncryptedSecretRecordMapper.recordType else { continue }
            guard let secret = EncryptedSecretRecordMapper.secret(from: record) else {
                let error = CloudKitKeySyncError.malformedRecord
                firstError = firstError ?? error
                log.error("Malformed encrypted secret record: \(record.recordID.recordName)")
                continue
            }

            do {
                try await applyRemoteSecret(secret, key: key, ensureActive: ensureActive)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                log.error("Could not apply encrypted secret \(secret.identifier): \(error.localizedDescription)")
            }
        }
        return firstError
    }

    /// Applies every fetched record deletion, returning the first failure.
    private func applyFetchedDeletions(
        _ deletedIDs: [CKRecord.ID],
        ensureActive: () throws -> Void
    ) async throws -> Error? {
        var firstError: Error?
        for recordID in deletedIDs {
            try ensureActive()
            guard let identifier = SyncSchema.EncryptedSecret.identifier(fromRecordName: recordID.recordName) else {
                continue
            }

            do {
                try await applyRemoteDeletion(
                    identifier: identifier,
                    updatedAt: cloud.dependencies.now(),
                    ensureActive: ensureActive
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                log.error("Could not apply encrypted secret deletion \(identifier): \(error.localizedDescription)")
            }
        }
        return firstError
    }

    private func applyRemoteSecret(
        _ secret: EncryptedSecret,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        guard CloudKitKeySync.syncableIdentifiers.contains(secret.identifier) else { return }
        let pendingMutation = pending.current(secret.identifier)
        let localUpdatedAt = try await effectiveLocalUpdatedAt(identifier: secret.identifier)
        guard localUpdatedAt == nil || secret.updatedAt > (localUpdatedAt ?? .distantPast) else { return }
        try ensureActive()

        applyingRemoteIdentifiers.insert(secret.identifier)
        defer { applyingRemoteIdentifiers.remove(secret.identifier) }

        if secret.isDeleted {
            try await secureStorage.removeSecret(identifier: secret.identifier)
        } else {
            let value = try EncryptedSecretCrypto.decryptSecret(secret, key: key)
            try await secureStorage.storeSecret(value, identifier: secret.identifier)
        }
        try ensureActive()
        try await localState.saveUpdatedAt(secret.updatedAt, identifier: secret.identifier)
        if let pendingMutation {
            pending.clear(ifMatching: pendingMutation)
        }
    }

    private func applyRemoteDeletion(
        identifier: String,
        updatedAt: Date,
        ensureActive: () throws -> Void
    ) async throws {
        guard CloudKitKeySync.syncableIdentifiers.contains(identifier) else { return }
        guard pending[identifier] == nil, pending.persisted(identifier) == nil else {
            return
        }
        try ensureActive()
        applyingRemoteIdentifiers.insert(identifier)
        defer { applyingRemoteIdentifiers.remove(identifier) }
        try await secureStorage.removeSecret(identifier: identifier)
        try ensureActive()
        try await localState.saveUpdatedAt(updatedAt, identifier: identifier)
    }
}

// MARK: - Uploading one mutation

extension KeySyncSecretTransfer {
    private func uploadSecret(
        _ mutation: PendingKeySyncMutation,
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws -> UploadResult {
        let isDeletion = mutation.kind == .deletion
        let value: String
        if isDeletion {
            value = ""
        } else {
            value = try await secureStorage.secret(identifier: mutation.identifier)
        }
        try ensureActive()
        let secret = try EncryptedSecretCrypto.encryptSecret(
            identifier: mutation.identifier,
            value: value,
            updatedAt: mutation.updatedAt,
            key: key,
            isDeleted: isDeletion
        )
        let recordID = CKRecord.ID(
            recordName: EncryptedSecretRecordMapper.recordName(for: mutation.identifier),
            zoneID: SyncConfiguration.zoneID
        )
        let existing = try await cloud.fetchRecord(id: recordID, database: database)
        try ensureActive()
        if let existing {
            guard let remoteSecret = EncryptedSecretRecordMapper.secret(from: existing) else {
                throw CloudKitKeySyncError.malformedRecord
            }
            if remoteSecret.updatedAt > mutation.updatedAt {
                try await applyRemoteSecret(remoteSecret, key: key, ensureActive: ensureActive)
                return .superseded
            }
        }
        let record = EncryptedSecretRecordMapper.record(from: secret, existingRecord: existing)
        _ = try await cloud.saveRecord(record, database: database)
        try ensureActive()
        return .uploaded
    }

    /// The newer of the committed local timestamp and any pending local edit.
    private func effectiveLocalUpdatedAt(identifier: String) async throws -> Date? {
        let committed = try await localState.loadUpdatedAt(identifier: identifier)
        guard let pendingMutation = pending.current(identifier) else { return committed }
        return max(committed ?? .distantPast, pendingMutation.updatedAt)
    }
}
