import CloudKit
import Combine
import Foundation
import os.log

/// Delegate protocol that platforms implement to handle synced entries.
@MainActor
public protocol HistorySyncDelegate: AnyObject {
    /// Return all local entries that should be uploaded.
    func pendingEntries() -> [SyncableHistoryEntry]

    /// Called when a new or updated entry arrives from CloudKit.
    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry)

    /// Called when an entry is deleted remotely.
    func didDeleteRemoteEntry(id: UUID)
}

/// Result of a CloudKit zone-changes fetch operation.
private struct FetchChangesResult {
    var records: [CKRecord]
    var deletedIDs: [CKRecord.ID]
    var serverChangeToken: CKServerChangeToken?
}

/// Main sync engine handling CloudKit operations for transcription history.
@MainActor
public final class HistorySyncEngine: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state = SyncState()

    // MARK: - Private Properties

    private weak var delegate: HistorySyncDelegate?
    private let log = Logger(
        subsystem: "com.justspeaktoit",
        category: "HistorySync"
    )

    // MARK: - Singleton

    public static let shared = HistorySyncEngine()

    private init() {}

    // MARK: - Initialization

    /// Initialize the sync engine with a delegate.
    public func initialize(delegate: HistorySyncDelegate) async {
        self.delegate = delegate
        await checkCloudAvailability()

        if state.isCloudAvailable {
            await setupCloudKitInfrastructure()
        }
    }

    // MARK: - Public API

    /// Manually trigger a full sync.
    public func sync() async {
        guard state.isCloudAvailable else {
            log.warning("Sync requested but iCloud unavailable")
            return
        }

        guard !state.isSyncing else {
            log.info("Sync already in progress")
            return
        }

        state.isSyncing = true
        state.error = nil

        defer { state.isSyncing = false }

        do {
            try await fetchRemoteChanges()
            try await uploadPendingEntries()
            state.lastSyncTime = Date()
            log.info("Sync completed successfully")
        } catch {
            state.error = error
            log.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Upload a single entry to CloudKit.
    public func upload(entry: SyncableHistoryEntry) async throws {
        guard state.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }

        let record = SyncRecord.record(from: entry)

        do {
            _ = try await SyncConfiguration.privateDatabase.save(record)
            log.debug("Uploaded entry: \(entry.id.uuidString)")
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    /// Delete an entry from CloudKit.
    public func delete(entryID: UUID) async throws {
        guard state.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }

        let recordID = CKRecord.ID(
            recordName: entryID.uuidString,
            zoneID: SyncConfiguration.zoneID
        )

        do {
            try await SyncConfiguration.privateDatabase.deleteRecord(
                withID: recordID
            )
            log.debug("Deleted entry: \(entryID.uuidString)")
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted — not an error
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    // MARK: - Cloud Availability

    private func checkCloudAvailability() async {
        guard SyncConfiguration.hasCloudKitEntitlement else {
            state.isCloudAvailable = false
            log.warning("CloudKit entitlement missing; history sync disabled")
            return
        }

        do {
            let status = try await SyncConfiguration.container.accountStatus()
            state.isCloudAvailable = (status == .available)
        } catch {
            state.isCloudAvailable = false
            log.warning("iCloud check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Infrastructure Setup

    private func setupCloudKitInfrastructure() async {
        if !UserDefaults.standard.bool(forKey: SyncConfiguration.zoneCreatedKey) {
            do {
                try await createCustomZone()
                UserDefaults.standard.set(true, forKey: SyncConfiguration.zoneCreatedKey)
            } catch {
                log.error("Zone creation failed: \(error.localizedDescription)")
            }
        }

        if !UserDefaults.standard.bool(forKey: SyncConfiguration.subscriptionCreatedKey) {
            do {
                try await createSubscription()
                UserDefaults.standard.set(true, forKey: SyncConfiguration.subscriptionCreatedKey)
            } catch {
                log.warning("Subscription failed: \(error.localizedDescription)")
            }
        }
    }

    private func createCustomZone() async throws {
        do {
            _ = try await SyncConfiguration.privateDatabase.save(SyncConfiguration.recordZone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists
        }
    }

    private func createSubscription() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: "transcription-history-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await SyncConfiguration.privateDatabase.save(subscription)
    }

    // MARK: - Fetch Remote Changes

    private func fetchRemoteChanges() async throws {
        let changeToken = loadChangeToken()
        let result = try await executeFetchOperation(changeToken: changeToken)

        for record in result.records {
            if let entry = SyncRecord.entry(from: record) {
                delegate?.didReceiveRemoteEntry(entry)
            }
        }

        for recordID in result.deletedIDs {
            if let uuid = UUID(uuidString: recordID.recordName) {
                delegate?.didDeleteRemoteEntry(id: uuid)
            }
        }

        if let token = result.serverChangeToken {
            saveChangeToken(token)
        }

        state.pendingDownloadCount = result.records.count
        log.info("Fetched \(result.records.count) records, \(result.deletedIDs.count) deletions")
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: SyncConfiguration.syncTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: SyncConfiguration.syncTokenKey)
        }
    }

    private func executeFetchOperation(
        changeToken: CKServerChangeToken?
    ) async throws -> FetchChangesResult {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = changeToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncConfiguration.zoneID],
            configurationsByRecordZoneID: [SyncConfiguration.zoneID: config]
        )

        var fetchedRecords: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?

        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result {
                fetchedRecords.append(record)
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            SyncConfiguration.privateDatabase.add(operation)
        }

        return FetchChangesResult(
            records: fetchedRecords,
            deletedIDs: deletedIDs,
            serverChangeToken: newToken
        )
    }

    // MARK: - Upload

    private func uploadPendingEntries() async throws {
        guard let delegate else { return }

        let entries = delegate.pendingEntries()
        guard !entries.isEmpty else { return }

        state.pendingUploadCount = entries.count
        let records = entries.map { SyncRecord.record(from: $0) }

        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            SyncConfiguration.privateDatabase.add(operation)
        }

        log.info("Uploaded \(records.count) records")
    }
}
