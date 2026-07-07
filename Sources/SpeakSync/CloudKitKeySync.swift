import CloudKit
import Combine
import CryptoKit
import Foundation
import os.log
import Security

import SpeakCore

// swiftlint:disable file_length

public struct EncryptedSecret: Equatable, Sendable {
    public let identifier: String
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    public let updatedAt: Date
    public let isDeleted: Bool

    public init(
        identifier: String,
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.identifier = identifier
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public struct CloudKitKeySyncStatus: Equatable, Sendable {
    public var isEnabled: Bool
    public var isCloudAvailable: Bool
    public var isSyncing: Bool
    public var lastSyncTime: Date?
    public var lastErrorDescription: String?

    public init(
        isEnabled: Bool = false,
        isCloudAvailable: Bool = false,
        isSyncing: Bool = false,
        lastSyncTime: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.isCloudAvailable = isCloudAvailable
        self.isSyncing = isSyncing
        self.lastSyncTime = lastSyncTime
        self.lastErrorDescription = lastErrorDescription
    }

    public var message: String {
        if let lastErrorDescription { return lastErrorDescription }
        if !isCloudAvailable { return "CloudKit unavailable" }
        if !isEnabled { return "Off" }
        if isSyncing { return "Syncing…" }
        if let lastSyncTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSyncTime, relativeTo: Date()))"
        }
        return "Ready"
    }
}

public enum CloudKitKeySyncError: LocalizedError, Equatable {
    case cloudUnavailable
    case missingPassphrase
    case incorrectPassphrase
    case encryptionFailed
    case malformedRecord

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "CloudKit is unavailable for this build, device, or iCloud account."
        case .missingPassphrase:
            return "Enter the API-key sync passphrase to join this device."
        case .incorrectPassphrase:
            return "The API-key sync passphrase is incorrect."
        case .encryptionFailed:
            return "Failed to encrypt or decrypt the API key."
        case .malformedRecord:
            return "CloudKit returned an invalid encrypted key record."
        }
    }
}

public enum EncryptedSecretCrypto {
    private static let info = Data("justspeaktoit.api-key-sync.v1".utf8)
    private static let verifierPlaintext = Data("justspeaktoit.api-key-sync.verifier.v1".utf8)

    /// Derives the local encryption key from a user-owned passphrase and a CloudKit-stored salt.
    /// The passphrase is never sent to CloudKit. CloudKit stores only the random salt and an
    /// AES-GCM verification token, so iCloud private-database access alone cannot read API keys.
    /// A device joins sync by entering the passphrase once; the derived key is then kept only in
    /// that device's Keychain via SecureStorage, not in CloudKit.
    public static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    public static func encryptSecret(
        identifier: String,
        value: String,
        updatedAt: Date,
        key: SymmetricKey,
        isDeleted: Bool = false
    ) throws -> EncryptedSecret {
        let sealedBox = try AES.GCM.seal(Data(value.utf8), using: key)
        return EncryptedSecret(
            identifier: identifier,
            ciphertext: sealedBox.ciphertext,
            nonce: Data(sealedBox.nonce),
            tag: sealedBox.tag,
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }

    public static func decryptSecret(_ secret: EncryptedSecret, key: SymmetricKey) throws -> String {
        let nonce = try AES.GCM.Nonce(data: secret.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: secret.ciphertext,
            tag: secret.tag
        )
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return value
    }

    struct VerificationToken {
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    static func makeVerificationToken(key: SymmetricKey) throws -> VerificationToken {
        let sealedBox = try AES.GCM.seal(verifierPlaintext, using: key)
        return VerificationToken(
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    static func verifyToken(nonce: Data, ciphertext: Data, tag: Data, key: SymmetricKey) -> Bool {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: key)
            return plaintext == verifierPlaintext
        } catch {
            return false
        }
    }
}

public enum EncryptedSecretRecordMapper {
    public static let recordType = "EncryptedSecret"

    private enum FieldKey {
        static let identifier = "identifier"
        static let ciphertext = "ciphertext"
        static let nonce = "nonce"
        static let tag = "tag"
        static let updatedAt = "updatedAt"
        static let isDeleted = "isDeleted"
    }

    public static func recordName(for identifier: String) -> String {
        let encoded = Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "secret-\(encoded)"
    }

    public static func record(from secret: EncryptedSecret, existingRecord: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: recordName(for: secret.identifier),
            zoneID: SyncConfiguration.zoneID
        )
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        record[FieldKey.identifier] = secret.identifier
        record[FieldKey.ciphertext] = secret.ciphertext
        record[FieldKey.nonce] = secret.nonce
        record[FieldKey.tag] = secret.tag
        record[FieldKey.updatedAt] = secret.updatedAt
        record[FieldKey.isDeleted] = secret.isDeleted ? 1 : 0
        return record
    }

    public static func secret(from record: CKRecord) -> EncryptedSecret? {
        guard record.recordType == recordType,
              let identifier = record[FieldKey.identifier] as? String,
              let ciphertext = record[FieldKey.ciphertext] as? Data,
              let nonce = record[FieldKey.nonce] as? Data,
              let tag = record[FieldKey.tag] as? Data,
              let updatedAt = record[FieldKey.updatedAt] as? Date else {
            return nil
        }
        let deletedValue = record[FieldKey.isDeleted]
        let isDeleted = (deletedValue as? Int) == 1 || (deletedValue as? Bool) == true
        return EncryptedSecret(
            identifier: identifier,
            ciphertext: ciphertext,
            nonce: nonce,
            tag: tag,
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }
}

private struct KeySyncMetadata {
    let salt: Data
    let verifierNonce: Data
    let verifierCiphertext: Data
    let verifierTag: Data
}

private enum KeySyncMetadataRecordMapper {
    static let recordType = "EncryptedSecretMetadata"
    static let recordName = "api-key-sync-metadata"

    private enum FieldKey {
        static let salt = "salt"
        static let verifierNonce = "verifierNonce"
        static let verifierCiphertext = "verifierCiphertext"
        static let verifierTag = "verifierTag"
        static let updatedAt = "updatedAt"
    }

    static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: SyncConfiguration.zoneID)
    }

    static func record(from metadata: KeySyncMetadata, existingRecord: CKRecord? = nil) -> CKRecord {
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        record[FieldKey.salt] = metadata.salt
        record[FieldKey.verifierNonce] = metadata.verifierNonce
        record[FieldKey.verifierCiphertext] = metadata.verifierCiphertext
        record[FieldKey.verifierTag] = metadata.verifierTag
        record[FieldKey.updatedAt] = Date()
        return record
    }

    static func metadata(from record: CKRecord) -> KeySyncMetadata? {
        guard record.recordType == recordType,
              let salt = record[FieldKey.salt] as? Data,
              let nonce = record[FieldKey.verifierNonce] as? Data,
              let ciphertext = record[FieldKey.verifierCiphertext] as? Data,
              let tag = record[FieldKey.verifierTag] as? Data else {
            return nil
        }
        return KeySyncMetadata(
            salt: salt,
            verifierNonce: nonce,
            verifierCiphertext: ciphertext,
            verifierTag: tag
        )
    }
}

private struct KeySyncFetchResult {
    var records: [CKRecord]
    var deletedIDs: [CKRecord.ID]
    var serverChangeToken: CKServerChangeToken?
}

@MainActor
// swiftlint:disable:next type_body_length
public final class CloudKitKeySync: ObservableObject {
    public static let shared = CloudKitKeySync()

    public nonisolated static let syncableIdentifiers: Set<String> = [
        "deepgram.apiKey",
        "openai.apiKey",
        "openrouter.apiKey",
        "elevenlabs.apiKey",
        "cartesia.apiKey",
        "assemblyai.apiKey",
        "gladia.apiKey",
        "modulate.apiKey",
        "soniox.apiKey"
    ]

    @Published public private(set) var status = CloudKitKeySyncStatus()

    private static let enabledKey = "speak.keysync.enabled"
    private static let syncTokenKey = "speak.keysync.serverChangeToken"
    private static let subscriptionCreatedKey = "speak.keysync.subscriptionCreated"
    private static let zoneCreatedKey = "speak.keysync.zoneCreated"
    private static let localDerivedKeyIdentifier = "cloudkitKeySync.derivedKey"
    private static let localUpdatedPrefix = "speak.keysync.localUpdatedAt."
    private static let subscriptionID = "encrypted-secret-changes"
    private static let localUploadDebounceNanoseconds: UInt64 = 750_000_000

    private let log = Logger(subsystem: "com.justspeaktoit", category: "CloudKitKeySync")
    private var secureStorage: SecureStorage
    private var symmetricKey: SymmetricKey?
    private var observer: NSObjectProtocol?
    private var applyingRemoteIdentifiers = Set<String>()
    private var pendingLocalUploadDates: [String: Date] = [:]
    private var localUploadTasks: [String: Task<Void, Never>] = [:]

    private init(secureStorage: SecureStorage = SecureStorage()) {
        self.secureStorage = secureStorage
        self.status.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        observeLocalKeyChanges()
    }

    public func configure(secureStorage: SecureStorage) async {
        self.secureStorage = secureStorage
        await restoreSavedKeyIfNeeded()
    }

    public func isAvailable() async -> Bool {
        guard SyncConfiguration.hasCloudKitEntitlement,
              let container = SyncConfiguration.container else {
            status.isCloudAvailable = false
            return false
        }

        do {
            let accountStatus = try await container.accountStatus()
            status.isCloudAvailable = accountStatus == .available
            return status.isCloudAvailable
        } catch {
            status.isCloudAvailable = false
            status.lastErrorDescription = error.localizedDescription
            return false
        }
    }

    public func enable(passphrase: String) async throws {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudKitKeySyncError.missingPassphrase }
        guard await isAvailable(), let database = SyncConfiguration.privateDatabase else {
            throw CloudKitKeySyncError.cloudUnavailable
        }

        try await setupCloudKitInfrastructure(database: database)
        let key = try await loadOrCreateMetadataKey(passphrase: trimmed, database: database)
        symmetricKey = key
        try await secureStorage.storeSecret(
            key.withUnsafeBytes { Data($0).base64EncodedString() },
            identifier: Self.localDerivedKeyIdentifier
        )
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        status.isEnabled = true
        status.lastErrorDescription = nil
        try await syncNow()
    }

    public func disable() async {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        try? await secureStorage.removeSecret(identifier: Self.localDerivedKeyIdentifier)
        localUploadTasks.values.forEach { $0.cancel() }
        localUploadTasks.removeAll()
        pendingLocalUploadDates.removeAll()
        symmetricKey = nil
        status.isEnabled = false
        status.lastErrorDescription = nil
    }

    public func syncNow() async throws {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        await restoreSavedKeyIfNeeded()
        guard let key = symmetricKey else { throw CloudKitKeySyncError.missingPassphrase }
        guard await isAvailable(), let database = SyncConfiguration.privateDatabase else {
            throw CloudKitKeySyncError.cloudUnavailable
        }

        status.isSyncing = true
        status.lastErrorDescription = nil
        defer { status.isSyncing = false }

        do {
            try await setupCloudKitInfrastructure(database: database)
            try await fetchRemoteChanges(database: database, key: key)
            try await uploadLocalSecrets(database: database, key: key)
            status.lastSyncTime = Date()
        } catch {
            status.lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    public func handleRemoteNotification() async {
        try? await syncNow()
    }

    private func observeLocalKeyChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: SecureStorage.didChangeSecretNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let identifier = notification
                    .userInfo?[SecureStorage.NotificationUserInfoKey.identifier] as? String,
                  Self.syncableIdentifiers.contains(identifier) else {
                return
            }

            Task { @MainActor in
                guard !self.applyingRemoteIdentifiers.contains(identifier),
                      self.status.isEnabled else {
                    return
                }
                let updatedAt = notification
                    .userInfo?[SecureStorage.NotificationUserInfoKey.updatedAt] as? Date ?? Date()
                self.scheduleLocalUpload(identifier: identifier, updatedAt: updatedAt)
            }
        }
    }

    private func scheduleLocalUpload(identifier: String, updatedAt: Date) {
        pendingLocalUploadDates[identifier] = updatedAt

        guard localUploadTasks[identifier] == nil else { return }

        localUploadTasks[identifier] = Task { @MainActor [weak self] in
            defer {
                self?.localUploadTasks[identifier] = nil
            }

            while !Task.isCancelled {
                let observedUpdatedAt = self?.pendingLocalUploadDates[identifier]
                do {
                    try await Task.sleep(nanoseconds: Self.localUploadDebounceNanoseconds)
                } catch {
                    return
                }

                guard let self else { return }
                guard self.pendingLocalUploadDates[identifier] == observedUpdatedAt else {
                    continue
                }
                guard let updatedAt = self.pendingLocalUploadDates.removeValue(forKey: identifier),
                      self.status.isEnabled,
                      let key = self.symmetricKey,
                      let database = SyncConfiguration.privateDatabase else {
                    return
                }

                await self.saveLocalUpdatedAt(updatedAt, identifier: identifier)

                do {
                    try await self.uploadSecret(
                        identifier: identifier,
                        updatedAt: updatedAt,
                        database: database,
                        key: key
                    )
                } catch {
                    self.log.error("Debounced key upload failed for \(identifier): \(error.localizedDescription)")
                }

                if self.pendingLocalUploadDates[identifier] == nil {
                    return
                }
            }
        }
    }

    private func restoreSavedKeyIfNeeded() async {
        guard symmetricKey == nil,
              UserDefaults.standard.bool(forKey: Self.enabledKey),
              let stored = try? await secureStorage.secret(identifier: Self.localDerivedKeyIdentifier),
              let data = Data(base64Encoded: stored) else {
            return
        }
        symmetricKey = SymmetricKey(data: data)
    }

    private func setupCloudKitInfrastructure(database: CKDatabase) async throws {
        if !UserDefaults.standard.bool(forKey: Self.zoneCreatedKey) {
            do {
                _ = try await database.save(SyncConfiguration.recordZone)
                UserDefaults.standard.set(true, forKey: Self.zoneCreatedKey)
            } catch let error as CKError where error.code == .serverRecordChanged {
                UserDefaults.standard.set(true, forKey: Self.zoneCreatedKey)
            }
        }

        if !UserDefaults.standard.bool(forKey: Self.subscriptionCreatedKey) {
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            do {
                _ = try await database.save(subscription)
                UserDefaults.standard.set(true, forKey: Self.subscriptionCreatedKey)
            } catch let error as CKError where error.code == .serverRejectedRequest {
                log.warning("Key sync subscription unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func loadOrCreateMetadataKey(passphrase: String, database: CKDatabase) async throws -> SymmetricKey {
        if let record = try await fetchRecord(id: KeySyncMetadataRecordMapper.recordID, database: database) {
            guard let metadata = KeySyncMetadataRecordMapper.metadata(from: record) else {
                throw CloudKitKeySyncError.malformedRecord
            }
            let key = EncryptedSecretCrypto.deriveKey(passphrase: passphrase, salt: metadata.salt)
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

        let salt = randomData(byteCount: 32)
        let key = EncryptedSecretCrypto.deriveKey(passphrase: passphrase, salt: salt)
        let token = try EncryptedSecretCrypto.makeVerificationToken(key: key)
        let metadata = KeySyncMetadata(
            salt: salt,
            verifierNonce: token.nonce,
            verifierCiphertext: token.ciphertext,
            verifierTag: token.tag
        )
        _ = try await database.save(KeySyncMetadataRecordMapper.record(from: metadata))
        return key
    }

    private func fetchRemoteChanges(database: CKDatabase, key: SymmetricKey) async throws {
        let result = try await executeFetchOperation(database: database, changeToken: loadChangeToken())

        for record in result.records {
            guard let secret = EncryptedSecretRecordMapper.secret(from: record) else {
                log.warning("Skipping malformed encrypted secret record: \(record.recordID.recordName)")
                continue
            }

            do {
                try await applyRemoteSecret(secret, key: key)
            } catch {
                log.error("Skipping encrypted secret \(secret.identifier): \(error.localizedDescription)")
            }
        }

        for recordID in result.deletedIDs {
            guard let identifier = identifierFromRecordName(recordID.recordName) else { continue }

            do {
                try await applyRemoteDeletion(identifier: identifier, updatedAt: Date())
            } catch {
                log.error("Skipping encrypted secret deletion \(identifier): \(error.localizedDescription)")
            }
        }

        if let token = result.serverChangeToken {
            saveChangeToken(token)
        }
    }

    private func applyRemoteSecret(_ secret: EncryptedSecret, key: SymmetricKey) async throws {
        guard Self.syncableIdentifiers.contains(secret.identifier) else { return }
        let localUpdatedAt = await loadLocalUpdatedAt(identifier: secret.identifier)
        guard localUpdatedAt == nil || secret.updatedAt >= (localUpdatedAt ?? .distantPast) else { return }

        applyingRemoteIdentifiers.insert(secret.identifier)
        defer { applyingRemoteIdentifiers.remove(secret.identifier) }

        if secret.isDeleted {
            try await secureStorage.removeSecret(identifier: secret.identifier)
        } else {
            let value = try EncryptedSecretCrypto.decryptSecret(secret, key: key)
            try await secureStorage.storeSecret(value, identifier: secret.identifier)
        }
        await saveLocalUpdatedAt(secret.updatedAt, identifier: secret.identifier)
    }

    private func applyRemoteDeletion(identifier: String, updatedAt: Date) async throws {
        guard Self.syncableIdentifiers.contains(identifier) else { return }
        applyingRemoteIdentifiers.insert(identifier)
        defer { applyingRemoteIdentifiers.remove(identifier) }
        try await secureStorage.removeSecret(identifier: identifier)
        await saveLocalUpdatedAt(updatedAt, identifier: identifier)
    }

    private func uploadLocalSecrets(database: CKDatabase, key: SymmetricKey) async throws {
        let identifiers = (await secureStorage.knownIdentifiers())
            .filter { Self.syncableIdentifiers.contains($0) }
            .prefix(SyncConfiguration.batchSize)
        for identifier in identifiers {
            let updatedAt = await loadLocalUpdatedAt(identifier: identifier) ?? Date()
            try await uploadSecret(identifier: identifier, updatedAt: updatedAt, database: database, key: key)
            await saveLocalUpdatedAt(updatedAt, identifier: identifier)
        }
    }

    private func uploadSecret(
        identifier: String,
        updatedAt: Date,
        database: CKDatabase,
        key: SymmetricKey
    ) async throws {
        let value = (try? await secureStorage.secret(identifier: identifier)) ?? ""
        let isDeleted = value.isEmpty
        let secret = try EncryptedSecretCrypto.encryptSecret(
            identifier: identifier,
            value: value,
            updatedAt: updatedAt,
            key: key,
            isDeleted: isDeleted
        )
        let recordID = CKRecord.ID(
            recordName: EncryptedSecretRecordMapper.recordName(for: identifier),
            zoneID: SyncConfiguration.zoneID
        )
        let existing = try await fetchRecord(id: recordID, database: database)
        let record = EncryptedSecretRecordMapper.record(from: secret, existingRecord: existing)
        _ = try await database.save(record)
    }

    private func executeFetchOperation(
        database: CKDatabase,
        changeToken: CKServerChangeToken?
    ) async throws -> KeySyncFetchResult {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = changeToken
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncConfiguration.zoneID],
            configurationsByRecordZoneID: [SyncConfiguration.zoneID: config]
        )

        var records: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?

        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result {
                records.append(record)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedIDs.append(recordID)
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            newToken = token
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let (token, _, _)) = result {
                newToken = token
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }

        return KeySyncFetchResult(records: records, deletedIDs: deletedIDs, serverChangeToken: newToken)
    }

    private func fetchRecord(id: CKRecord.ID, database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.syncTokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.syncTokenKey)
        }
    }

    private func saveLocalUpdatedAt(_ date: Date, identifier: String) async {
        try? await secureStorage.storeSecret(
            String(date.timeIntervalSince1970),
            identifier: Self.localUpdatedPrefix + identifier
        )
    }

    private func loadLocalUpdatedAt(identifier: String) async -> Date? {
        guard let value = try? await secureStorage.secret(identifier: Self.localUpdatedPrefix + identifier),
              let timestamp = TimeInterval(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func randomData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func identifierFromRecordName(_ recordName: String) -> String? {
        guard recordName.hasPrefix("secret-") else { return nil }
        var encoded = String(recordName.dropFirst("secret-".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
