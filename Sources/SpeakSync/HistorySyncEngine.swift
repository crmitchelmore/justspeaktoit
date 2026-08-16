import CloudKit
import Combine
import Foundation
import SpeakCore
import os.log

/// Delegate protocol that platforms implement to reconcile synced entries.
@MainActor
public protocol HistorySyncDelegate: AnyObject {
    /// Return local entries that are not currently acknowledged by CloudKit.
    func pendingEntries() -> [SyncableHistoryEntry]

    /// Reconcile a new, duplicate, or updated entry from CloudKit.
    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async

    /// Reconcile a CloudKit tombstone.
    func didDeleteRemoteEntry(id: UUID) async

    /// Record IDs that CloudKit has acknowledged.
    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async
}

enum HistoryRemoteChange {
    case changed(SyncableHistoryEntry)
    case deleted(UUID)

    var id: UUID {
        switch self {
        case .changed(let entry):
            return entry.id
        case .deleted(let id):
            return id
        }
    }
}

struct HistoryChangePage {
    var changes: [HistoryRemoteChange]
    var serverChangeTokenData: Data?
    var moreComing: Bool
}

struct HistoryUploadResult {
    var acknowledgedIDs: Set<UUID>
    var remoteEntries: [SyncableHistoryEntry]
    var failures: [UUID: Error]

    static func success(ids: Set<UUID>) -> HistoryUploadResult {
        HistoryUploadResult(acknowledgedIDs: ids, remoteEntries: [], failures: [:])
    }
}

@MainActor
protocol HistorySyncTransport: AnyObject {
    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage
    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult
    func delete(entryID: UUID) async throws
}

/// Keeps only the final event for each record while preserving the order of
/// those final events. This makes duplicate changes and tombstones deterministic
/// across CloudKit pages.
enum HistoryChangeReconciler {
    static func coalesced(_ changes: [HistoryRemoteChange]) -> [HistoryRemoteChange] {
        var latestByID: [UUID: (offset: Int, change: HistoryRemoteChange)] = [:]
        for (offset, change) in changes.enumerated() {
            latestByID[change.id] = (offset, change)
        }
        return latestByID.values
            .sorted { $0.offset < $1.offset }
            .map(\.change)
    }
}

/// Main sync engine handling CloudKit operations for transcription history.
@MainActor
public final class HistorySyncEngine: ObservableObject {
    @Published public private(set) var state = SyncState()

    public static let shared = HistorySyncEngine()

    private weak var delegate: HistorySyncDelegate?
    private let transport: HistorySyncTransport
    private let defaults: UserDefaults
    private let log = SpeakLogger.logger(category: "HistorySync")

    private convenience init() {
        self.init(
            transport: CloudKitHistorySyncTransport(),
            defaults: .standard,
            cloudAvailable: false
        )
    }

    init(
        transport: HistorySyncTransport,
        defaults: UserDefaults,
        cloudAvailable: Bool,
        delegate: HistorySyncDelegate? = nil
    ) {
        self.transport = transport
        self.defaults = defaults
        self.delegate = delegate
        state.isCloudAvailable = cloudAvailable
    }

    public func initialize(delegate: HistorySyncDelegate) async {
        self.delegate = delegate
        await checkCloudAvailability()
        if state.isCloudAvailable {
            await setupCloudKitInfrastructure()
        }
    }

    /// Manually trigger a complete fetch, reconciliation, and upload pass.
    public func sync() async {
        state.pendingUploadCount = delegate?.pendingEntries().count ?? 0
        state.pendingDownloadCount = 0

        guard state.isCloudAvailable else {
            state.error = SyncError.cloudUnavailable
            log.warning("Sync requested but iCloud unavailable")
            return
        }
        guard !state.isSyncing else {
            log.info("Sync already in progress")
            return
        }
        guard delegate != nil else {
            state.error = SyncError.delegateUnavailable
            return
        }

        state.isSyncing = true
        state.error = nil
        defer { state.isSyncing = false }

        do {
            try await fetchRemoteChanges()
            try await uploadPendingEntries()
            state.pendingDownloadCount = 0
            state.pendingUploadCount = delegate?.pendingEntries().count ?? 0
            guard state.pendingUploadCount == 0 else {
                throw SyncError.reconciliationIncomplete(state.pendingUploadCount)
            }
            state.lastSyncTime = Date()
            log.info("Sync reconciliation completed successfully")
        } catch {
            state.error = error
            state.pendingUploadCount = delegate?.pendingEntries().count ?? state.pendingUploadCount
            log.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Upload a single entry and acknowledge it only after CloudKit confirms it.
    public func upload(entry: SyncableHistoryEntry) async throws {
        guard state.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }
        // Without a delegate the acknowledgement cannot be persisted, so the
        // entry would upload again after relaunch. Fail before touching the
        // transport and leave the entry pending.
        guard delegate != nil else {
            let syncError = SyncError.delegateUnavailable
            state.error = syncError
            throw syncError
        }
        let result = await transport.upload(entries: [entry])
        await applyUploadResult(result)
        state.pendingUploadCount = delegate?.pendingEntries().count ?? 0
        if let error = result.failures[entry.id] {
            let syncError = SyncError.cloudKit(error)
            state.error = syncError
            throw syncError
        }
        state.error = nil
        log.debug("Uploaded entry: \(entry.id.uuidString)")
    }

    public func delete(entryID: UUID) async throws {
        guard state.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }
        do {
            try await transport.delete(entryID: entryID)
            log.debug("Deleted entry: \(entryID.uuidString)")
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    private func checkCloudAvailability() async {
        guard SyncConfiguration.hasCloudKitEntitlement else {
            state.isCloudAvailable = false
            state.error = SyncError.cloudUnavailable
            log.warning("CloudKit entitlement missing; history sync disabled")
            return
        }
        do {
            let status = try await SyncConfiguration.container?.accountStatus() ?? .noAccount
            state.isCloudAvailable = status == .available
            state.error = state.isCloudAvailable ? nil : SyncError.cloudUnavailable
        } catch {
            state.isCloudAvailable = false
            state.error = SyncError.cloudKit(error)
            log.warning("iCloud check failed: \(error.localizedDescription)")
        }
    }

    private func setupCloudKitInfrastructure() async {
        if !defaults.bool(forKey: SyncConfiguration.zoneCreatedKey) {
            do {
                try await createCustomZone()
                defaults.set(true, forKey: SyncConfiguration.zoneCreatedKey)
            } catch {
                log.error("Zone creation failed: \(error.localizedDescription)")
            }
        }
        if !defaults.bool(forKey: SyncConfiguration.subscriptionCreatedKey) {
            do {
                try await createSubscription()
                defaults.set(true, forKey: SyncConfiguration.subscriptionCreatedKey)
            } catch {
                log.warning("Subscription failed: \(error.localizedDescription)")
            }
        }
    }

    private func createCustomZone() async throws {
        guard let database = SyncConfiguration.privateDatabase else { return }
        do {
            _ = try await database.save(SyncConfiguration.recordZone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists.
        }
    }

    private func createSubscription() async throws {
        guard let database = SyncConfiguration.privateDatabase else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: "transcription-history-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    private func fetchRemoteChanges() async throws {
        var tokenData = defaults.data(forKey: SyncConfiguration.syncTokenKey)
        var finalTokenData = tokenData
        var allChanges: [HistoryRemoteChange] = []

        while true {
            let page = try await transport.fetchChanges(after: tokenData)
            allChanges.append(contentsOf: page.changes)
            state.pendingDownloadCount = allChanges.count

            if let pageToken = page.serverChangeTokenData {
                guard !page.moreComing || pageToken != tokenData else {
                    throw SyncError.invalidChangePage
                }
                tokenData = pageToken
                finalTokenData = pageToken
            } else if page.moreComing {
                throw SyncError.invalidChangePage
            }

            if !page.moreComing {
                break
            }
        }

        let changes = HistoryChangeReconciler.coalesced(allChanges)
        state.pendingDownloadCount = changes.count
        for change in changes {
            switch change {
            case .changed(let entry):
                await delegate?.didReceiveRemoteEntry(entry)
            case .deleted(let id):
                await delegate?.didDeleteRemoteEntry(id: id)
            }
            state.pendingDownloadCount -= 1
        }

        if let finalTokenData {
            defaults.set(finalTokenData, forKey: SyncConfiguration.syncTokenKey)
        }
        log.info("Reconciled \(changes.count) final remote changes")
    }

    private func uploadPendingEntries() async throws {
        guard let delegate else { return }

        while true {
            let pending = delegate.pendingEntries()
            state.pendingUploadCount = pending.count
            guard !pending.isEmpty else { return }

            let batch = Array(pending.prefix(SyncConfiguration.batchSize))
            let result = await transport.upload(entries: batch)
            await applyUploadResult(result)
            state.pendingUploadCount = delegate.pendingEntries().count

            if !result.failures.isEmpty {
                throw SyncError.partialUploadFailure(result.failures.count)
            }
            guard state.pendingUploadCount < pending.count else {
                throw SyncError.reconciliationIncomplete(state.pendingUploadCount)
            }
        }
    }

    private func applyUploadResult(_ result: HistoryUploadResult) async {
        for entry in result.remoteEntries {
            await delegate?.didReceiveRemoteEntry(entry)
        }
        if !result.acknowledgedIDs.isEmpty {
            await delegate?.didAcknowledgeSyncedEntries(ids: result.acknowledgedIDs)
        }
    }
}
