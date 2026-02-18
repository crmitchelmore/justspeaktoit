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

        defer {
            state.isSyncing = false
        }

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
            log.debug("Deleted entry from CloudKit: \(entryID.uuidString)")
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted — not an error
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    // MARK: - Private Methods

    private func checkCloudAvailability() async {
        do {
            let status = try await SyncConfiguration.container.accountStatus()
            state.isCloudAvailable = (status == .available)
            log.info(
                "iCloud status: \(status == .available ? "available" : "unavailable")"
            )
        } catch {
            state.isCloudAvailable = false
            log.warning(
                "Failed to check iCloud status: \(error.localizedDescription)"
            )
        }
    }

    private func setupCloudKitInfrastructure() async {
        let zoneCreated = UserDefaults.standard.bool(
            forKey: SyncConfiguration.zoneCreatedKey
        )
        if !zoneCreated {
            do {
                try await createCustomZone()
                UserDefaults.standard.set(
                    true,
                    forKey: SyncConfiguration.zoneCreatedKey
                )
            } catch {
                log.error(
                    "Failed to create CloudKit zone: \(error.localizedDescription)"
                )
            }
        }

        let subscriptionCreated = UserDefaults.standard.bool(
            forKey: SyncConfiguration.subscriptionCreatedKey
        )
        if !subscriptionCreated {
            do {
                try await createSubscription()
                UserDefaults.standard.set(
                    true,
                    forKey: SyncConfiguration.subscriptionCreatedKey
                )
            } catch {
                log.warning(
                    "Failed to create subscription: \(error.localizedDescription)"
                )
            }
        }
    }

    private func createCustomZone() async throws {
        let zone = SyncConfiguration.recordZone

        do {
            _ = try await SyncConfiguration.privateDatabase.save(zone)
            log.info("Created CloudKit zone: \(zone.zoneID.zoneName)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists — fine
        }
    }

    private func createSubscription() async throws {
        let subscription = CKDatabaseSubscription(
            subscriptionID: "transcription-history-changes"
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        _ = try await SyncConfiguration.privateDatabase.save(subscription)
        log.info("Created CloudKit subscription")
    }

    private func fetchRemoteChanges() async throws {
        var changeToken: CKServerChangeToken?
        if let tokenData = UserDefaults.standard.data(
            forKey: SyncConfiguration.syncTokenKey
        ) {
            changeToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: tokenData
            )
        }

        let configuration = CKFetchRecordZoneChangesOperation
            .ZoneConfiguration()
        configuration.previousServerChangeToken = changeToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncConfiguration.zoneID],
            configurationsByRecordZoneID: [
                SyncConfiguration.zoneID: configuration
            ]
        )

        var fetchedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?

        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                fetchedRecords.append(record)
            case .failure(let error):
                self.log.warning(
                    "Failed to fetch record: \(error.localizedDescription)"
                )
            }
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }

        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            newToken = token
        }

        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (serverChangeToken, _, _)):
                newToken = serverChangeToken
            case .failure(let error):
                self.log.error(
                    "Zone fetch failed: \(error.localizedDescription)"
                )
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            SyncConfiguration.privateDatabase.add(operation)
        }

        // Process fetched records
        for record in fetchedRecords {
            if let entry = SyncRecord.entry(from: record) {
                delegate?.didReceiveRemoteEntry(entry)
            }
        }

        // Process deletions
        for recordID in deletedRecordIDs {
            if let uuid = UUID(uuidString: recordID.recordName) {
                delegate?.didDeleteRemoteEntry(id: uuid)
            }
        }

        // Save new token
        if let token = newToken,
            let tokenData = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
            )
        {
            UserDefaults.standard.set(
                tokenData,
                forKey: SyncConfiguration.syncTokenKey
            )
        }

        state.pendingDownloadCount = fetchedRecords.count
        log.info(
            "Fetched \(fetchedRecords.count) records, \(deletedRecordIDs.count) deletions"
        )
    }

    private func uploadPendingEntries() async throws {
        guard let delegate else { return }

        let entries = delegate.pendingEntries()
        guard !entries.isEmpty else { return }

        state.pendingUploadCount = entries.count

        let records = entries.map { SyncRecord.record(from: $0) }

        let operation = CKModifyRecordsOperation(
            recordsToSave: records,
            recordIDsToDelete: nil
        )
        operation.savePolicy = .changedKeys
        operation.isAtomic = false

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            SyncConfiguration.privateDatabase.add(operation)
        }

        log.info("Uploaded \(records.count) records")
    }
}
