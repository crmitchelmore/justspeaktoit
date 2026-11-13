import CloudKit
import CryptoKit
import Foundation
import SpeakCore

// MARK: - One-time carry-over from the legacy container (#1119)

extension CloudKitKeySync {
    /// Keeps key sync switched on when this device moved to the shared
    /// container. CloudKit user record names differ per container, so the
    /// stored fingerprint, which `SyncContainerTransition` kept aside, is
    /// compared with the legacy container's account instead. A match means
    /// the same iCloud account: the fingerprint is rewritten for the shared
    /// container and the carry-over is queued. A mismatch falls through to the
    /// normal account-change reset. A failed lookup throws, wiping nothing, so
    /// the next attempt retries.
    func adoptLegacyContainerAccountIfNeeded(fingerprint: String) async throws {
        let defaults = dependencies.defaults
        guard let legacyFingerprint = defaults.string(forKey: Self.legacyAccountIdentifierKey) else { return }
        guard defaults.string(forKey: Self.accountIdentifierKey) == nil,
              let legacyAccountRecordName = dependencies.legacyAccountRecordName else {
            defaults.removeObject(forKey: Self.legacyAccountIdentifierKey)
            return
        }
        let legacyRecordName = try await legacyAccountRecordName()
        if Self.accountFingerprint(legacyRecordName) == legacyFingerprint {
            defaults.set(fingerprint, forKey: Self.accountIdentifierKey)
            defaults.set(true, forKey: Self.legacyContainerCopyPendingKey)
        }
        defaults.removeObject(forKey: Self.legacyAccountIdentifierKey)
    }

    /// Carries this device's keys into the shared container once. The shared
    /// container gets passphrase metadata with the legacy salt, so the same
    /// passphrase keeps working; keys in the legacy container are applied
    /// locally, then the shared container's newer copies win, and every
    /// local key is queued for upload, re-encrypted for the shared container
    /// by the normal upload path. When the shared container already holds
    /// metadata for another passphrase, key sync turns off and asks for it.
    func carryLegacyContainerSecretsIfNeeded(
        database: CloudKitKeySyncDatabase,
        key: SymmetricKey,
        ensureActive: () throws -> Void
    ) async throws {
        let defaults = dependencies.defaults
        guard defaults.bool(forKey: Self.legacyContainerCopyPendingKey) else { return }
        guard let legacyDatabase = dependencies.legacyDatabase?() else {
            defaults.removeObject(forKey: Self.legacyContainerCopyPendingKey)
            return
        }

        let legacyMetadata = try await metadata(in: legacyDatabase)
        let legacyKeyMatches = legacyMetadata.map { Self.verifies($0, key: key) } ?? false
        if let current = try await metadata(in: database) {
            guard Self.verifies(current, key: key) else {
                try await requirePassphraseForSharedContainer()
                throw CloudKitKeySyncError.missingPassphrase
            }
        } else {
            guard let legacyMetadata, legacyKeyMatches else {
                try await requirePassphraseForSharedContainer()
                throw CloudKitKeySyncError.missingPassphrase
            }
            let token = try EncryptedSecretCrypto.makeVerificationToken(key: key)
            let metadata = KeySyncMetadata(
                salt: legacyMetadata.salt,
                verifierNonce: token.nonce,
                verifierCiphertext: token.ciphertext,
                verifierTag: token.tag
            )
            _ = try await transfer.cloud.saveRecord(
                KeySyncMetadataRecordMapper.record(from: metadata, updatedAt: dependencies.now()),
                database: database
            )
        }
        try ensureActive()

        if legacyKeyMatches {
            transfer.cloud.clearChangeToken()
            do {
                try await transfer.fetchRemoteChanges(database: legacyDatabase, key: key, ensureActive: ensureActive)
            } catch where SyncContainerTransition.isMissingZone(error) {
                // The legacy container holds no keys on this account.
            } catch {
                transfer.cloud.clearChangeToken()
                throw error
            }
            transfer.cloud.clearChangeToken()
            try ensureActive()
            try await transfer.fetchRemoteChanges(database: database, key: key, ensureActive: ensureActive)
            try ensureActive()
        }
        try await transfer.seedPendingMutationsForExistingSecrets()
        defaults.removeObject(forKey: Self.legacyContainerCopyPendingKey)
        log.info("Carried API-key sync into the shared CloudKit container")
    }

    private func metadata(in database: CloudKitKeySyncDatabase) async throws -> KeySyncMetadata? {
        let record: CKRecord?
        do {
            record = try await transfer.cloud.fetchRecord(id: KeySyncMetadataRecordMapper.recordID, database: database)
        } catch where SyncContainerTransition.isMissingZone(error) {
            return nil
        }
        guard let record else { return nil }
        guard let metadata = KeySyncMetadataRecordMapper.metadata(from: record) else {
            throw CloudKitKeySyncError.malformedRecord
        }
        return metadata
    }

    private static func verifies(_ metadata: KeySyncMetadata, key: SymmetricKey) -> Bool {
        EncryptedSecretCrypto.verifyToken(
            nonce: metadata.verifierNonce,
            ciphertext: metadata.verifierCiphertext,
            tag: metadata.verifierTag,
            key: key
        )
    }

    /// Turns key sync off on this device without touching the stored keys,
    /// so turning it back on with the shared container's passphrase rejoins.
    private func requirePassphraseForSharedContainer() async throws {
        let defaults = dependencies.defaults
        defaults.removeObject(forKey: Self.legacyContainerCopyPendingKey)
        defaults.set(false, forKey: Self.enabledKey)
        symmetricKey = nil
        status.isEnabled = false
        transfer.pending.removeAll()
        try await transfer.localState.removeDerivedKey()
    }
}
