import Foundation

/// One synced API key as another client wrote it, after decryption.
public struct CloudKitWebSyncedSecret: Equatable, Sendable {
    public let identifier: String
    /// The decrypted value, or `nil` for a deletion.
    public let value: String?
    public let updatedAt: Date

    public init(identifier: String, value: String?, updatedAt: Date) {
        self.identifier = identifier
        self.value = value
        self.updatedAt = updatedAt
    }

    public var isDeleted: Bool { value == nil }
}

/// What one read of the synced API keys found.
public struct CloudKitWebKeySyncSnapshot: Equatable, Sendable {
    /// Readable keys and deletions, one per identifier, sorted by identifier.
    public var secrets: [CloudKitWebSyncedSecret]
    /// Identifiers whose record exists but could not be read or opened.
    public var unreadableIdentifiers: [String]

    public init(secrets: [CloudKitWebSyncedSecret], unreadableIdentifiers: [String]) {
        self.secrets = secrets
        self.unreadableIdentifiers = unreadableIdentifiers
    }
}

public enum CloudKitWebKeySyncError: Error, Equatable, Sendable {
    /// The account has no key-sync metadata: no Apple device turned API-key sync on.
    case noSyncedKeys
}

extension CloudKitWebKeySyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSyncedKeys:
            return "This iCloud account has no synced API keys. Turn on API-key sync on your Mac first."
        }
    }
}

/// Reads the passphrase-encrypted API keys an Apple device syncs through
/// `CloudKitKeySync`, over CloudKit Web Services.
///
/// The records are plain CloudKit fields holding AES-256-GCM sealed boxes; the
/// key is derived on the device from the user's passphrase and never stored in
/// CloudKit. Reading them therefore needs the same passphrase, exactly as a new
/// Apple device joining key sync does, and weakens nothing on the Apple side.
///
/// This client only reads. It never creates the metadata, re-encrypts a key or
/// writes a tombstone, so the Apple engine stays the only writer. Record names
/// are derived from the canonical identifier list, so one lookup reads every
/// key without walking the History change feed.
public enum CloudKitWebKeySync {
    /// Derives and verifies the key-sync key for `passphrase` against the
    /// account's stored salt and verifier. Keep the result as a credential;
    /// the passphrase itself is not needed again.
    public static func unlock(
        passphrase: String,
        client: CloudKitWebServicesClient,
        consent: CloudKitWebSyncConsent,
        envelope: EncryptedSecretEnvelope
    ) async throws -> Data {
        try consent.require(.apiKeys)
        let normalized = try EncryptedSecretEnvelope.normalizedPassphrase(passphrase)
        let session = await client.session()
        let metadata = try await fetchMetadata(client: client, session: session)
        return try envelope.unlock(metadata, passphrase: normalized)
    }

    /// Reads and opens every syncable key with a key from `unlock`. A key that
    /// no longer matches the account's verifier (the passphrase was reset on
    /// another device) fails with `CloudKitKeySyncError.incorrectPassphrase`,
    /// so the host asks for the passphrase again. Within a sync pass, pass its
    /// validated session as `in:`, so a sign-in partway through never reads
    /// another user's keys with this one's key.
    public static func read(
        key: Data,
        client: CloudKitWebServicesClient,
        consent: CloudKitWebSyncConsent,
        envelope: EncryptedSecretEnvelope,
        in pinned: CloudKitWebSession? = nil
    ) async throws -> CloudKitWebKeySyncSnapshot {
        try consent.require(.apiKeys)
        let session = await client.session(or: pinned)
        let identifiers = SyncSchema.EncryptedSecret.syncableIdentifiers.sorted()
        let names = [SyncSchema.KeySyncMetadata.recordName]
            + identifiers.map(SyncSchema.EncryptedSecret.recordName(for:))
        let outcomes = try await CloudKitWebRecordBatch.lookup(
            names,
            zoneName: SyncSchema.zoneName,
            client: client,
            session: session
        )
        let metadata = try metadata(from: outcomes[SyncSchema.KeySyncMetadata.recordName])
        guard envelope.verifies(metadata, key: key) else { throw CloudKitKeySyncError.incorrectPassphrase }

        var snapshot = CloudKitWebKeySyncSnapshot(secrets: [], unreadableIdentifiers: [])
        for identifier in identifiers {
            switch outcomes[SyncSchema.EncryptedSecret.recordName(for: identifier)] {
            case .absent?:
                continue
            case .found(let record)?:
                if let secret = open(record, identifier: identifier, key: key, envelope: envelope) {
                    snapshot.secrets.append(secret)
                } else {
                    snapshot.unreadableIdentifiers.append(identifier)
                }
            case .failed(let error)?:
                throw error
            case nil:
                throw CloudKitWebRecordBatch.missingResult
            }
        }
        return snapshot
    }

    private static func fetchMetadata(
        client: CloudKitWebServicesClient,
        session: CloudKitWebSession
    ) async throws -> KeySyncMetadata {
        let name = SyncSchema.KeySyncMetadata.recordName
        let outcomes = try await CloudKitWebRecordBatch.lookup(
            [name],
            zoneName: SyncSchema.zoneName,
            client: client,
            session: session
        )
        return try metadata(from: outcomes[name])
    }

    private static func metadata(from outcome: CloudKitWebLookupOutcome?) throws -> KeySyncMetadata {
        switch outcome {
        case .found(let record)?:
            guard let metadata = KeySyncMetadataRecordCodec.metadata(from: record) else {
                throw CloudKitKeySyncError.malformedRecord
            }
            return metadata
        case .absent?:
            throw CloudKitWebKeySyncError.noSyncedKeys
        case .failed(let error)?:
            throw error
        case nil:
            throw CloudKitWebRecordBatch.missingResult
        }
    }

    /// A record whose stored identifier disagrees with its name is refused, so
    /// a key can never be applied under another provider's credential.
    private static func open(
        _ record: CloudKitWebRecord,
        identifier: String,
        key: Data,
        envelope: EncryptedSecretEnvelope
    ) -> CloudKitWebSyncedSecret? {
        guard let secret = EncryptedSecretRecordCodec.secret(from: record),
              secret.identifier == identifier else {
            return nil
        }
        if secret.isDeleted {
            return CloudKitWebSyncedSecret(identifier: identifier, value: nil, updatedAt: secret.updatedAt)
        }
        guard let value = try? envelope.open(secret, key: key) else { return nil }
        return CloudKitWebSyncedSecret(identifier: identifier, value: value, updatedAt: secret.updatedAt)
    }
}
