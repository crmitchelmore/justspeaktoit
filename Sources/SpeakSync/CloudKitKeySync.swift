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
    case passphraseTooShort(minimumLength: Int)
    case randomGenerationFailed
    case notConfigured

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
        case .passphraseTooShort(let minimumLength):
            return "Use an API-key sync passphrase with at least \(minimumLength) characters."
        case .randomGenerationFailed:
            return "Failed to generate secure random bytes for API-key sync."
        case .notConfigured:
            return "API-key sync has not finished configuring secure storage."
        }
    }
}

public enum EncryptedSecretCrypto {
    private static let info = Data("justspeaktoit.api-key-sync.v1".utf8)
    private static let verifierPlaintext = Data("justspeaktoit.api-key-sync.verifier.v1".utf8)
    private static let keyByteCount = 32
    private static let pbkdf2Iterations = 210_000
    public static let minimumPassphraseLength = 12

    /// Derives the local encryption key from a user-owned passphrase and a CloudKit-stored salt.
    /// The passphrase is never sent to CloudKit. CloudKit stores only the random salt and an
    /// AES-GCM verification token, so iCloud private-database access alone cannot read API keys.
    /// A device joins sync by entering the passphrase once; the derived key is then kept only in
    /// that device's Keychain via SecureStorage, not in CloudKit.
    public static func validatePassphrase(_ passphrase: String) throws {
        guard passphrase.count >= minimumPassphraseLength else {
            throw CloudKitKeySyncError.passphraseTooShort(minimumLength: minimumPassphraseLength)
        }
    }

    public static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let derived = pbkdf2SHA256(
            password: Data(passphrase.utf8),
            salt: salt + info,
            iterations: pbkdf2Iterations,
            keyByteCount: keyByteCount
        )
        return SymmetricKey(data: derived)
    }

    static func deriveKeyOffMainActor(passphrase: String, salt: Data) async -> SymmetricKey {
        let keyData = await Task.detached(priority: .userInitiated) {
            deriveKey(passphrase: passphrase, salt: salt).withUnsafeBytes { Data($0) }
        }.value
        return SymmetricKey(data: keyData)
    }

    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) -> Data {
        let hmacKey = SymmetricKey(data: password)
        let blockCount = Int(ceil(Double(keyByteCount) / Double(SHA256.byteCount)))
        var derived = Data()

        for blockIndex in 1...blockCount {
            var blockSalt = salt
            var bigEndianIndex = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &bigEndianIndex) { blockSalt.append(contentsOf: $0) }

            var iterationOutput = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: hmacKey))
            var block = iterationOutput

            if iterations > 1 {
                for _ in 2...iterations {
                    iterationOutput = Data(HMAC<SHA256>.authenticationCode(for: iterationOutput, using: hmacKey))
                    for index in block.indices {
                        block[index] ^= iterationOutput[index]
                    }
                }
            }

            derived.append(block)
        }

        return Data(derived.prefix(keyByteCount))
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
    var moreComing: Bool
}

struct PendingKeySyncMutation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case update
        case deletion
    }

    let operationID: UUID
    let identifier: String
    let updatedAt: Date
    let kind: Kind
}

private final class KeySyncFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord] = []
    private var deletedIDs: [CKRecord.ID] = []
    private var serverChangeToken: CKServerChangeToken?
    private var moreComing = false
    private var errors: [Error] = []

    func append(record: CKRecord) {
        lock.withLock { records.append(record) }
    }

    func appendDeletedID(_ recordID: CKRecord.ID) {
        lock.withLock { deletedIDs.append(recordID) }
    }

    func updateToken(_ token: CKServerChangeToken?) {
        guard let token else { return }
        lock.withLock { serverChangeToken = token }
    }

    func updateMoreComing(_ value: Bool) {
        lock.withLock { moreComing = value }
    }

    func append(error: Error) {
        lock.withLock { errors.append(error) }
    }

    func result() throws -> KeySyncFetchResult {
        let snapshot = lock.withLock {
            (
                errors.first,
                KeySyncFetchResult(
                    records: records,
                    deletedIDs: deletedIDs,
                    serverChangeToken: serverChangeToken,
                    moreComing: moreComing
                )
            )
        }
        if let error = snapshot.0 {
            throw error
        }
        return snapshot.1
    }
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
    private static let accountIdentifierKey = "speak.keysync.accountIdentifier"
    private static let pendingMutationPrefix = "speak.keysync.pending."
    private static let localDerivedKeyIdentifier = "cloudkitKeySync.derivedKey"
    private static let localUpdatedPrefix = "speak.keysync.localUpdatedAt."
    private static let subscriptionID = "encrypted-secret-changes"
    private static let localUploadDebounceNanoseconds: UInt64 = 750_000_000
    private static let localUploadInitialRetryNanoseconds: UInt64 = 2_000_000_000
    private static let localUploadMaximumRetryNanoseconds: UInt64 = 60_000_000_000

    private struct ActiveSync {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct SuspendedWork {
        let syncTask: Task<Void, Error>?
        let uploadTasks: [Task<Void, Never>]
    }

    private enum SecretUploadResult: Equatable {
        case uploaded
        case superseded
    }

    private let log = Logger(subsystem: "com.justspeaktoit", category: "CloudKitKeySync")
    private let stateStorage: SecureStorage
    private var secureStorage: SecureStorage
    private var isConfigured = false
    private var symmetricKey: SymmetricKey?
    private var observer: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private var applyingRemoteIdentifiers = Set<String>()
    private var pendingMutations: [String: PendingKeySyncMutation] = [:]
    private var retryAttempts: [String: Int] = [:]
    private var localUploadTasks: [String: Task<Void, Never>] = [:]
    private var localUploadTaskIDs: [String: UUID] = [:]
    private var activeSync: ActiveSync?
    private var syncGeneration: UInt64 = 0
    private var lifecycleIsLocked = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    private init(
        secureStorage: SecureStorage = SecureStorage(),
        stateStorage: SecureStorage = SecureStorage(
            configuration: SecureStorageConfiguration(
                service: "com.justspeaktoit.keysync-state",
                masterAccount: "cloudkit-key-sync-state",
                accessGroup: nil,
                synchronizable: false
            )
        )
    ) {
        self.secureStorage = secureStorage
        self.stateStorage = stateStorage
        self.pendingMutations = Self.loadPersistedPendingMutations()
        observeLocalKeyChanges()
        observeCloudKitAccountChanges()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    public func configure(secureStorage: SecureStorage) async {
        self.secureStorage = secureStorage
        isConfigured = true
    }

    public func isAvailable() async -> Bool {
        guard SyncConfiguration.hasCloudKitEntitlement,
              let container = SyncConfiguration.container else {
            status.isCloudAvailable = false
            return false
        }

        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status.isCloudAvailable = false
                return false
            }
            try await validateCurrentAccount(container: container)
            status.isCloudAvailable = true
            status.lastErrorDescription = nil
            status.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
            if status.isEnabled, isConfigured {
                await restoreSavedKeyIfNeeded()
                restorePendingMutationTasks()
            }
            return true
        } catch {
            status.isCloudAvailable = false
            status.lastErrorDescription = error.localizedDescription
            return false
        }
    }

    public func enable(passphrase: String) async throws {
        guard isConfigured else { throw CloudKitKeySyncError.notConfigured }
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudKitKeySyncError.missingPassphrase }
        try EncryptedSecretCrypto.validatePassphrase(trimmed)
        guard await isAvailable(), let database = SyncConfiguration.privateDatabase else {
            throw CloudKitKeySyncError.cloudUnavailable
        }

        await acquireLifecycleLock()
        do {
            let generation = syncGeneration
            try await setupCloudKitInfrastructure(database: database)
            try ensureGenerationIsCurrent(generation)
            let key = try await loadOrCreateMetadataKey(passphrase: trimmed, database: database)
            try ensureGenerationIsCurrent(generation)
            symmetricKey = key
            try await stateStorage.storeSecret(
                key.withUnsafeBytes { Data($0).base64EncodedString() },
                identifier: Self.localDerivedKeyIdentifier
            )
            try ensureGenerationIsCurrent(generation)
            try await seedPendingMutationsForExistingSecrets()
            try ensureGenerationIsCurrent(generation)
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            status.isEnabled = true
            status.lastErrorDescription = nil
            restorePendingMutationTasks()
            try ensureSyncIsActive(generation: generation)
        } catch {
            releaseLifecycleLock()
            throw error
        }
        releaseLifecycleLock()
        try await syncNow()
    }

    public func disable() async {
        await acquireLifecycleLock()
        defer { releaseLifecycleLock() }
        let syncTask = activeSync?.task
        let uploadTasks = Array(localUploadTasks.values)
        syncGeneration &+= 1
        syncTask?.cancel()
        uploadTasks.forEach { $0.cancel() }
        activeSync = nil
        localUploadTasks.removeAll()
        localUploadTaskIDs.removeAll()
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        symmetricKey = nil
        status.isEnabled = false
        status.isSyncing = false

        if let syncTask {
            do {
                try await syncTask.value
            } catch is CancellationError {
                // Expected when disabling an active sync.
            } catch {
                log.warning("Active key sync stopped with error during disable: \(error.localizedDescription)")
            }
        }
        for task in uploadTasks {
            await task.value
        }

        retryAttempts.removeAll()
        pendingMutations.removeAll()
        Self.clearPersistedPendingMutations()
        do {
            try await stateStorage.removeSecret(identifier: Self.localDerivedKeyIdentifier)
        } catch {
            log.error("Could not remove the local key-sync key: \(error.localizedDescription)")
        }
        status.lastSyncTime = nil
        status.lastErrorDescription = nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func syncNow() async throws {
        guard isConfigured else { throw CloudKitKeySyncError.notConfigured }
        if let activeSync {
            try await activeSync.task.value
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        guard await isAvailable(), let database = SyncConfiguration.privateDatabase else {
            throw CloudKitKeySyncError.cloudUnavailable
        }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        await restoreSavedKeyIfNeeded()
        guard let key = symmetricKey else { throw CloudKitKeySyncError.missingPassphrase }

        if let activeSync {
            try await activeSync.task.value
            return
        }
        let id = UUID()
        let generation = syncGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performSync(
                database: database,
                key: key,
                generation: generation
            )
        }
        activeSync = ActiveSync(id: id, task: task)
        do {
            try await task.value
        } catch {
            if activeSync?.id == id {
                activeSync = nil
            }
            throw error
        }
        if activeSync?.id == id {
            activeSync = nil
        }
    }

    public func handleRemoteNotification() async throws {
        try await syncNow()
    }

    private func performSync(
        database: CKDatabase,
        key: SymmetricKey,
        generation: UInt64
    ) async throws {
        try ensureSyncIsActive(generation: generation)

        status.isSyncing = true
        status.lastErrorDescription = nil
        defer {
            if generation == syncGeneration {
                status.isSyncing = false
            }
        }

        do {
            try await setupCloudKitInfrastructure(database: database)
            try ensureSyncIsActive(generation: generation)
            try await fetchRemoteChanges(database: database, key: key, generation: generation)
            try ensureSyncIsActive(generation: generation)
            try await uploadLocalSecrets(database: database, key: key, generation: generation)
            try ensureSyncIsActive(generation: generation)
            status.lastSyncTime = Date()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == syncGeneration {
                status.lastErrorDescription = error.localizedDescription
            }
            throw error
        }
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
                      UserDefaults.standard.bool(forKey: Self.enabledKey) else {
                    return
                }
                let updatedAt = notification
                    .userInfo?[SecureStorage.NotificationUserInfoKey.updatedAt] as? Date ?? Date()
                let operation = notification
                    .userInfo?[SecureStorage.NotificationUserInfoKey.operation] as? String
                let mutation = PendingKeySyncMutation(
                    operationID: UUID(),
                    identifier: identifier,
                    updatedAt: updatedAt,
                    kind: operation == "remove" ? .deletion : .update
                )
                Self.persistPendingMutation(mutation)
                self.pendingMutations[identifier] = mutation
                self.scheduleLocalUpload(identifier: identifier)
            }
        }
    }

    private func observeCloudKitAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleCloudKitAccountChange()
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func scheduleLocalUpload(identifier: String) {
        guard localUploadTasks[identifier] == nil,
              pendingMutations[identifier] != nil else {
            return
        }

        let generation = syncGeneration
        let taskID = UUID()
        localUploadTaskIDs[identifier] = taskID
        localUploadTasks[identifier] = Task { @MainActor [weak self] in
            defer {
                if self?.localUploadTaskIDs[identifier] == taskID {
                    self?.localUploadTasks[identifier] = nil
                    self?.localUploadTaskIDs[identifier] = nil
                    self?.retryAttempts[identifier] = nil
                }
            }

            while !Task.isCancelled {
                guard let self,
                      let observedMutation = self.pendingMutations[identifier] else {
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: Self.localUploadDebounceNanoseconds)
                } catch {
                    return
                }

                guard self.pendingMutations[identifier]?.operationID == observedMutation.operationID else {
                    continue
                }
                if self.activeSync != nil {
                    continue
                }
                guard let key = self.symmetricKey,
                      let database = SyncConfiguration.privateDatabase else {
                    return
                }

                do {
                    try self.ensureSyncIsActive(generation: generation)
                    let uploadResult = try await self.uploadSecret(
                        identifier: identifier,
                        updatedAt: observedMutation.updatedAt,
                        database: database,
                        key: key,
                        isDeletion: observedMutation.kind == .deletion,
                        generation: generation
                    )
                    if uploadResult == .uploaded {
                        try await self.saveLocalUpdatedAt(observedMutation.updatedAt, identifier: identifier)
                        self.clearPendingMutation(ifMatching: observedMutation)
                    }
                    self.retryAttempts[identifier] = nil
                } catch is CancellationError {
                    return
                } catch {
                    self.log.error("Debounced key upload failed for \(identifier): \(error.localizedDescription)")
                    let attempt = (self.retryAttempts[identifier] ?? 0) + 1
                    self.retryAttempts[identifier] = attempt
                    let shift = UInt64(min(attempt - 1, 5))
                    let delay = min(
                        Self.localUploadInitialRetryNanoseconds << shift,
                        Self.localUploadMaximumRetryNanoseconds
                    )
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                }

                if self.pendingMutations[identifier] == nil {
                    return
                }
            }
        }
    }

    private func restoreSavedKeyIfNeeded() async {
        guard symmetricKey == nil,
              UserDefaults.standard.bool(forKey: Self.enabledKey),
              let stored = try? await stateStorage.secret(identifier: Self.localDerivedKeyIdentifier),
              let data = Data(base64Encoded: stored) else {
            return
        }
        symmetricKey = SymmetricKey(data: data)
    }

    private func restorePendingMutationTasks() {
        pendingMutations = Self.loadPersistedPendingMutations()
        for identifier in pendingMutations.keys {
            scheduleLocalUpload(identifier: identifier)
        }
    }

    private func seedPendingMutationsForExistingSecrets() async throws {
        var mutationsToPersist: [PendingKeySyncMutation] = []
        for identifier in Self.syncableIdentifiers.sorted() where pendingMutations[identifier] == nil {
            do {
                _ = try await secureStorage.secret(identifier: identifier)
                mutationsToPersist.append(PendingKeySyncMutation(
                    operationID: UUID(),
                    identifier: identifier,
                    updatedAt: Date(),
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
            Self.persistPendingMutation(mutation)
            pendingMutations[mutation.identifier] = mutation
        }
    }

    private func clearPendingMutation(ifMatching mutation: PendingKeySyncMutation) {
        guard pendingMutations[mutation.identifier]?.operationID == mutation.operationID,
              Self.loadPersistedPendingMutation(identifier: mutation.identifier)?.operationID
                == mutation.operationID else {
            return
        }
        pendingMutations[mutation.identifier] = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingMutationKey(identifier: mutation.identifier))
    }

    private static func pendingMutationKey(identifier: String) -> String {
        pendingMutationPrefix + identifier
    }

    private static func persistPendingMutation(_ mutation: PendingKeySyncMutation) {
        guard let data = try? JSONEncoder().encode(mutation) else { return }
        UserDefaults.standard.set(data, forKey: pendingMutationKey(identifier: mutation.identifier))
    }

    private static func loadPersistedPendingMutation(identifier: String) -> PendingKeySyncMutation? {
        guard let data = UserDefaults.standard.data(forKey: pendingMutationKey(identifier: identifier)) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingKeySyncMutation.self, from: data)
    }

    private static func loadPersistedPendingMutations() -> [String: PendingKeySyncMutation] {
        syncableIdentifiers.reduce(into: [:]) { mutations, identifier in
            mutations[identifier] = loadPersistedPendingMutation(identifier: identifier)
        }
    }

    private static func clearPersistedPendingMutations() {
        for identifier in syncableIdentifiers {
            UserDefaults.standard.removeObject(forKey: pendingMutationKey(identifier: identifier))
        }
    }

    private func validateCurrentAccount(container: CKContainer) async throws {
        let recordName = try await container.userRecordID().recordName
        let fingerprint = SHA256.hash(data: Data(recordName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try await resetAccountBoundState(ifNeededFor: fingerprint)
    }

    private func handleCloudKitAccountChange() async {
        let suspendedWork = suspendActiveWork()
        await acquireLifecycleLock()
        symmetricKey = nil
        status.isEnabled = false
        status.isCloudAvailable = false
        await waitForSuspendedWork(suspendedWork)
        releaseLifecycleLock()
        _ = await isAvailable()
    }

    private func resetAccountBoundState(ifNeededFor fingerprint: String) async throws {
        await acquireLifecycleLock()
        defer { releaseLifecycleLock() }
        guard UserDefaults.standard.string(forKey: Self.accountIdentifierKey) != fingerprint else {
            return
        }
        let suspendedWork = suspendActiveWork()
        await waitForSuspendedWork(suspendedWork)
        pendingMutations.removeAll()
        retryAttempts.removeAll()
        Self.clearPersistedPendingMutations()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.syncTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.zoneCreatedKey)
        UserDefaults.standard.removeObject(forKey: Self.subscriptionCreatedKey)
        try await stateStorage.removeSecret(identifier: Self.localDerivedKeyIdentifier)
        for identifier in Self.syncableIdentifiers {
            try await stateStorage.removeSecret(identifier: Self.localUpdatedPrefix + identifier)
        }
        symmetricKey = nil
        status.isEnabled = false
        status.isSyncing = false
        status.lastSyncTime = nil
        status.lastErrorDescription = nil
        UserDefaults.standard.set(fingerprint, forKey: Self.accountIdentifierKey)
    }

    private func suspendActiveWork() -> SuspendedWork {
        let suspendedWork = SuspendedWork(
            syncTask: activeSync?.task,
            uploadTasks: Array(localUploadTasks.values)
        )
        syncGeneration &+= 1
        suspendedWork.syncTask?.cancel()
        suspendedWork.uploadTasks.forEach { $0.cancel() }
        activeSync = nil
        localUploadTasks.removeAll()
        localUploadTaskIDs.removeAll()
        retryAttempts.removeAll()
        status.isSyncing = false
        return suspendedWork
    }

    private func waitForSuspendedWork(_ suspendedWork: SuspendedWork) async {
        if let syncTask = suspendedWork.syncTask {
            do {
                try await syncTask.value
            } catch is CancellationError {
                // Expected after invalidating the previous account generation.
            } catch {
                log.warning("Suspended key sync ended with error: \(error.localizedDescription)")
            }
        }
        for task in suspendedWork.uploadTasks {
            await task.value
        }
    }

    private func acquireLifecycleLock() async {
        guard lifecycleIsLocked else {
            lifecycleIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    private func releaseLifecycleLock() {
        guard !lifecycleWaiters.isEmpty else {
            lifecycleIsLocked = false
            return
        }
        lifecycleWaiters.removeFirst().resume()
    }

    private func ensureSyncIsActive(generation: UInt64) throws {
        try ensureGenerationIsCurrent(generation)
        guard UserDefaults.standard.bool(forKey: Self.enabledKey),
              status.isEnabled else {
            throw CancellationError()
        }
    }

    private func ensureGenerationIsCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration else {
            throw CancellationError()
        }
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

        let salt = try randomData(byteCount: 32)
        let key = await EncryptedSecretCrypto.deriveKeyOffMainActor(passphrase: passphrase, salt: salt)
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

    private func fetchRemoteChanges(
        database: CKDatabase,
        key: SymmetricKey,
        generation: UInt64
    ) async throws {
        do {
            try await fetchAndApplyRemoteChanges(
                database: database,
                key: key,
                changeToken: loadChangeToken(),
                generation: generation
            )
        } catch {
            guard Self.isChangeTokenExpired(error) else { throw error }
            clearChangeToken()
            try ensureSyncIsActive(generation: generation)
            try await fetchAndApplyRemoteChanges(
                database: database,
                key: key,
                changeToken: nil,
                generation: generation
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func fetchAndApplyRemoteChanges(
        database: CKDatabase,
        key: SymmetricKey,
        changeToken: CKServerChangeToken?,
        generation: UInt64
    ) async throws {
        let result = try await executeFetchOperation(database: database, changeToken: changeToken)
        try ensureSyncIsActive(generation: generation)
        var firstError: Error?

        for record in result.records {
            try ensureSyncIsActive(generation: generation)
            guard record.recordType == EncryptedSecretRecordMapper.recordType else { continue }
            guard let secret = EncryptedSecretRecordMapper.secret(from: record) else {
                let error = CloudKitKeySyncError.malformedRecord
                firstError = firstError ?? error
                log.error("Malformed encrypted secret record: \(record.recordID.recordName)")
                continue
            }

            do {
                try await applyRemoteSecret(secret, key: key, generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                log.error("Could not apply encrypted secret \(secret.identifier): \(error.localizedDescription)")
            }
        }

        for recordID in result.deletedIDs {
            try ensureSyncIsActive(generation: generation)
            guard let identifier = identifierFromRecordName(recordID.recordName) else { continue }

            do {
                try await applyRemoteDeletion(identifier: identifier, updatedAt: Date(), generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                log.error("Could not apply encrypted secret deletion \(identifier): \(error.localizedDescription)")
            }
        }

        if let firstError {
            throw firstError
        }
        try ensureSyncIsActive(generation: generation)
        if let token = result.serverChangeToken {
            saveChangeToken(token)
        }
    }

    private func applyRemoteSecret(
        _ secret: EncryptedSecret,
        key: SymmetricKey,
        generation: UInt64
    ) async throws {
        guard Self.syncableIdentifiers.contains(secret.identifier) else { return }
        let pendingMutation = pendingMutations[secret.identifier]
            ?? Self.loadPersistedPendingMutation(identifier: secret.identifier)
        let localUpdatedAt = try await effectiveLocalUpdatedAt(identifier: secret.identifier)
        guard localUpdatedAt == nil || secret.updatedAt > (localUpdatedAt ?? .distantPast) else { return }
        try ensureSyncIsActive(generation: generation)

        applyingRemoteIdentifiers.insert(secret.identifier)
        defer { applyingRemoteIdentifiers.remove(secret.identifier) }

        if secret.isDeleted {
            try await secureStorage.removeSecret(identifier: secret.identifier)
        } else {
            let value = try EncryptedSecretCrypto.decryptSecret(secret, key: key)
            try await secureStorage.storeSecret(value, identifier: secret.identifier)
        }
        try ensureSyncIsActive(generation: generation)
        try await saveLocalUpdatedAt(secret.updatedAt, identifier: secret.identifier)
        if let pendingMutation {
            clearPendingMutation(ifMatching: pendingMutation)
        }
    }

    private func applyRemoteDeletion(identifier: String, updatedAt: Date, generation: UInt64) async throws {
        guard Self.syncableIdentifiers.contains(identifier) else { return }
        guard pendingMutations[identifier] == nil,
              Self.loadPersistedPendingMutation(identifier: identifier) == nil else {
            return
        }
        try ensureSyncIsActive(generation: generation)
        applyingRemoteIdentifiers.insert(identifier)
        defer { applyingRemoteIdentifiers.remove(identifier) }
        try await secureStorage.removeSecret(identifier: identifier)
        try ensureSyncIsActive(generation: generation)
        try await saveLocalUpdatedAt(updatedAt, identifier: identifier)
    }

    private func uploadLocalSecrets(
        database: CKDatabase,
        key: SymmetricKey,
        generation: UInt64
    ) async throws {
        var firstError: Error?
        let mutations = Self.syncableIdentifiers
            .compactMap { identifier in
                pendingMutations[identifier]
                    ?? Self.loadPersistedPendingMutation(identifier: identifier)
            }
            .sorted { $0.identifier < $1.identifier }
            .prefix(SyncConfiguration.batchSize)

        for mutation in mutations {
            try ensureSyncIsActive(generation: generation)
            do {
                let uploadResult = try await uploadSecret(
                    identifier: mutation.identifier,
                    updatedAt: mutation.updatedAt,
                    database: database,
                    key: key,
                    isDeletion: mutation.kind == .deletion,
                    generation: generation
                )
                if uploadResult == .uploaded {
                    try await saveLocalUpdatedAt(mutation.updatedAt, identifier: mutation.identifier)
                    clearPendingMutation(ifMatching: mutation)
                }
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

    // swiftlint:disable:next function_parameter_count
    private func uploadSecret(
        identifier: String,
        updatedAt: Date,
        database: CKDatabase,
        key: SymmetricKey,
        isDeletion: Bool,
        generation: UInt64
    ) async throws -> SecretUploadResult {
        let value: String
        if isDeletion {
            value = ""
        } else {
            value = try await secureStorage.secret(identifier: identifier)
        }
        try ensureSyncIsActive(generation: generation)
        let secret = try EncryptedSecretCrypto.encryptSecret(
            identifier: identifier,
            value: value,
            updatedAt: updatedAt,
            key: key,
            isDeleted: isDeletion
        )
        let recordID = CKRecord.ID(
            recordName: EncryptedSecretRecordMapper.recordName(for: identifier),
            zoneID: SyncConfiguration.zoneID
        )
        let existing = try await fetchRecord(id: recordID, database: database)
        try ensureSyncIsActive(generation: generation)
        if let existing {
            guard let remoteSecret = EncryptedSecretRecordMapper.secret(from: existing) else {
                throw CloudKitKeySyncError.malformedRecord
            }
            if remoteSecret.updatedAt > updatedAt {
                try await applyRemoteSecret(remoteSecret, key: key, generation: generation)
                return .superseded
            }
        }
        let record = EncryptedSecretRecordMapper.record(from: secret, existingRecord: existing)
        _ = try await database.save(record)
        try ensureSyncIsActive(generation: generation)
        return .uploaded
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
        operation.fetchAllChanges = true

        let accumulator = KeySyncFetchAccumulator()

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

        return try accumulator.result()
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

    private func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: Self.syncTokenKey)
    }

    private static func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .changeTokenExpired {
            return true
        }
        return cloudError.partialErrorsByItemID?.values.contains {
            isChangeTokenExpired($0)
        } == true
    }

    private func saveLocalUpdatedAt(_ date: Date, identifier: String) async throws {
        try await stateStorage.storeSecret(
            String(date.timeIntervalSince1970),
            identifier: Self.localUpdatedPrefix + identifier
        )
    }

    private func loadLocalUpdatedAt(identifier: String) async throws -> Date? {
        let value: String
        do {
            value = try await stateStorage.secret(identifier: Self.localUpdatedPrefix + identifier)
        } catch SecureStorageError.valueNotFound {
            return nil
        }
        guard let timestamp = TimeInterval(value) else {
            throw CloudKitKeySyncError.malformedRecord
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func effectiveLocalUpdatedAt(identifier: String) async throws -> Date? {
        let committed = try await loadLocalUpdatedAt(identifier: identifier)
        let pending = pendingMutations[identifier]
            ?? Self.loadPersistedPendingMutation(identifier: identifier)
        guard let pending else { return committed }
        return max(committed ?? .distantPast, pending.updatedAt)
    }

    private func randomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CloudKitKeySyncError.randomGenerationFailed
        }
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
