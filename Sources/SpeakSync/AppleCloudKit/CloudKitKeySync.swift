import CloudKit
import Combine
import CryptoKit
import Foundation
import os.log

import SpeakCore

// `EncryptedSecret`, `CloudKitKeySyncError`, `KeySyncMetadata` and the envelope
// parameters are portable and live in KeySyncEnvelope.swift; the record format
// is `SyncSchema.EncryptedSecret` and `SyncSchema.KeySyncMetadata`. This file
// holds the public service and its lifecycle: enabling, disabling, account
// changes and the sync generation that cancels stale work. The work itself
// lives beside it: KeySyncSecretTransfer moves secrets in both directions,
// KeySyncUploadScheduler debounces local edits, KeySyncCloudOperations talks to
// CloudKit, KeySyncLocalState and KeySyncPendingMutations hold device state,
// EncryptedSecretCrypto is the CryptoKit envelope and KeySyncFetchOperation
// bridges the fetch operation.

@MainActor
public final class CloudKitKeySync: ObservableObject {
    public static let shared = CloudKitKeySync()

    /// The credential identifiers API-key sync carries; see `SyncSchema.EncryptedSecret`.
    public nonisolated static let syncableIdentifiers: Set<String> = SyncSchema.EncryptedSecret.syncableIdentifiers

    @Published public internal(set) var status = CloudKitKeySyncStatus()

    static let enabledKey = "speak.keysync.enabled"
    nonisolated static let syncTokenKey = "speak.keysync.serverChangeToken"
    nonisolated static let accountIdentifierKey = "speak.keysync.accountIdentifier"
    /// The account fingerprint from the container used before #1119.
    nonisolated static let legacyAccountIdentifierKey = "speak.keysync.legacyAccountIdentifier"
    /// Set when this device's keys still have to be carried into the shared container.
    static let legacyContainerCopyPendingKey = "speak.keysync.legacyContainerCopyPending"

    struct ActiveSync {
        let id: UUID
        let task: Task<Void, Error>
    }

    struct SuspendedWork {
        let syncTask: Task<Void, Error>?
        let uploadTasks: [Task<Void, Never>]
    }

    let log = SpeakLogger.logger(category: "CloudKitKeySync")
    let dependencies: CloudKitKeySyncDependencies
    let transfer: KeySyncSecretTransfer
    let uploads: KeySyncUploadScheduler
    let lifecycleLock = KeySyncLifecycleLock()
    private var isConfigured: Bool
    var symmetricKey: SymmetricKey?
    private var observer: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    var activeSync: ActiveSync?
    var syncGeneration: UInt64 = 0

    init(
        secureStorage: any CloudKitKeySyncSecretStoring = SecureStorage(),
        stateStorage: any CloudKitKeySyncSecretStoring = SecureStorage(
            configuration: SecureStorageConfiguration(
                service: "com.justspeaktoit.keysync-state",
                masterAccount: "cloudkit-key-sync-state",
                accessGroup: nil,
                synchronizable: false
            )
        ),
        dependencies: CloudKitKeySyncDependencies = .live,
        isConfigured: Bool = false,
        symmetricKey: SymmetricKey? = nil
    ) {
        self.dependencies = dependencies
        self.transfer = KeySyncSecretTransfer(
            secureStorage: secureStorage,
            localState: KeySyncLocalState(storage: stateStorage),
            cloud: KeySyncCloudOperations(dependencies: dependencies)
        )
        self.uploads = KeySyncUploadScheduler(sleep: dependencies.sleep)
        self.isConfigured = isConfigured
        self.symmetricKey = symmetricKey
        observeLocalKeyChanges()
        observeCloudKitAccountChanges()
    }

    deinit {
        if let observer {
            dependencies.notificationCenter.removeObserver(observer)
        }
        if let accountObserver {
            dependencies.notificationCenter.removeObserver(accountObserver)
        }
    }

    static func pendingMutationKey(identifier: String) -> String {
        KeySyncPendingMutations.key(identifier: identifier)
    }

    public func configure(secureStorage: SecureStorage) async {
        transfer.secureStorage = secureStorage
        isConfigured = true
    }

    public func isAvailable() async -> Bool {
        guard dependencies.hasCloudKitEntitlement(),
              dependencies.privateDatabase() != nil else {
            status.isCloudAvailable = false
            return false
        }

        do {
            let accountStatus = try await dependencies.accountStatus()
            guard accountStatus == .available else {
                status.isCloudAvailable = false
                return false
            }
            try await validateCurrentAccount()
            status.isCloudAvailable = true
            status.lastErrorDescription = nil
            status.isEnabled = dependencies.defaults.bool(forKey: Self.enabledKey)
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
        guard await isAvailable(), let database = dependencies.privateDatabase() else {
            throw CloudKitKeySyncError.cloudUnavailable
        }

        await lifecycleLock.acquire()
        do {
            let generation = syncGeneration
            try await transfer.cloud.setupInfrastructure(database: database)
            try ensureGenerationIsCurrent(generation)
            let key = try await transfer.cloud.loadOrCreateMetadataKey(passphrase: trimmed, database: database)
            try ensureGenerationIsCurrent(generation)
            symmetricKey = key
            try await transfer.localState.storeDerivedKey(key)
            try ensureGenerationIsCurrent(generation)
            try await transfer.seedPendingMutationsForExistingSecrets()
            try ensureGenerationIsCurrent(generation)
            dependencies.defaults.set(true, forKey: Self.enabledKey)
            status.isEnabled = true
            status.lastErrorDescription = nil
            restorePendingMutationTasks()
            try ensureSyncIsActive(generation: generation)
        } catch {
            lifecycleLock.release()
            throw error
        }
        lifecycleLock.release()
        try await syncNow()
    }

    public func disable() async {
        await lifecycleLock.acquire()
        defer { lifecycleLock.release() }
        let suspendedWork = suspendActiveWork()
        dependencies.defaults.set(false, forKey: Self.enabledKey)
        symmetricKey = nil
        status.isEnabled = false
        status.isSyncing = false
        await waitForSuspendedWork(suspendedWork, context: "Active key sync stopped with error during disable")

        uploads.clearRetries()
        transfer.pending.removeAll()
        do {
            try await transfer.localState.removeDerivedKey()
        } catch {
            log.error("Could not remove the local key-sync key: \(error.localizedDescription)")
        }
        status.lastSyncTime = nil
        status.lastErrorDescription = nil
    }

    public func syncNow() async throws {
        guard isConfigured else { throw CloudKitKeySyncError.notConfigured }
        if let activeSync {
            try await activeSync.task.value
            return
        }
        guard let (database, key) = try await prepareSync() else { return }
        if let activeSync {
            try await activeSync.task.value
            return
        }
        let id = UUID()
        let generation = syncGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performSync(database: database, key: key, generation: generation)
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

    /// The database and key a sync needs, or nil when sync is switched off.
    private func prepareSync() async throws -> (CloudKitKeySyncDatabase, SymmetricKey)? {
        guard dependencies.defaults.bool(forKey: Self.enabledKey) else { return nil }
        guard await isAvailable(), let database = dependencies.privateDatabase() else {
            throw CloudKitKeySyncError.cloudUnavailable
        }
        guard dependencies.defaults.bool(forKey: Self.enabledKey) else { return nil }
        await restoreSavedKeyIfNeeded()
        guard let key = symmetricKey else { throw CloudKitKeySyncError.missingPassphrase }
        return (database, key)
    }

    private func performSync(
        database: CloudKitKeySyncDatabase,
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

        let ensureActive = { try self.ensureSyncIsActive(generation: generation) }
        do {
            try await transfer.cloud.setupInfrastructure(database: database)
            try ensureActive()
            try await carryLegacyContainerSecretsIfNeeded(database: database, key: key, ensureActive: ensureActive)
            try ensureActive()
            try await transfer.fetchRemoteChanges(database: database, key: key, ensureActive: ensureActive)
            try ensureActive()
            try await transfer.uploadLocalSecrets(database: database, key: key, ensureActive: ensureActive)
            try ensureActive()
            status.lastSyncTime = dependencies.now()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == syncGeneration {
                status.lastErrorDescription = error.localizedDescription
            }
            throw error
        }
    }

    func restoreSavedKeyIfNeeded() async {
        guard symmetricKey == nil,
              dependencies.defaults.bool(forKey: Self.enabledKey),
              let key = await transfer.localState.loadDerivedKey() else {
            return
        }
        symmetricKey = key
    }

    func restorePendingMutationTasks() {
        transfer.pending.reloadPersisted()
        for identifier in transfer.pending.identifiers {
            uploads.schedule(identifier: identifier, generation: syncGeneration, host: self)
        }
    }
}

extension CloudKitKeySync: KeySyncUploadHost {
    func pendingMutation(for identifier: String) -> PendingKeySyncMutation? {
        transfer.pending[identifier]
    }

    var isFullSyncRunning: Bool { activeSync != nil }

    func uploadDebounced(_ mutation: PendingKeySyncMutation, generation: UInt64) async throws -> Bool {
        guard let key = symmetricKey,
              let database = dependencies.privateDatabase() else {
            return false
        }
        try ensureSyncIsActive(generation: generation)
        try await transfer.upload(
            mutation, database: database, key: key,
            ensureActive: { try self.ensureSyncIsActive(generation: generation) }
        )
        return true
    }
}

// MARK: - Notification observers

extension CloudKitKeySync {
    private func observeLocalKeyChanges() {
        observer = dependencies.notificationCenter.addObserver(
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
                guard !self.transfer.applyingRemoteIdentifiers.contains(identifier),
                      self.dependencies.defaults.bool(forKey: Self.enabledKey) else {
                    return
                }
                self.transfer.pending.record(PendingKeySyncMutation(
                    identifier: identifier, changeNotification: notification, now: self.dependencies.now
                ))
                self.uploads.schedule(identifier: identifier, generation: self.syncGeneration, host: self)
            }
        }
    }

    private func observeCloudKitAccountChanges() {
        accountObserver = dependencies.notificationCenter.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleCloudKitAccountChange()
            }
        }
    }
}
