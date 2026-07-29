import CloudKit
import Foundation

@MainActor
final class CloudKitHistorySyncTransport: HistorySyncTransport {
    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        guard let database = SyncConfiguration.privateDatabase else {
            throw SyncError.cloudUnavailable
        }

        let operation = try makeFetchOperation(after: tokenData)
        let accumulator = HistoryFetchAccumulator()
        configureCallbacks(for: operation, accumulator: accumulator)
        try await execute(operation, on: database)
        return try accumulator.page()
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        guard let database = SyncConfiguration.privateDatabase else {
            return HistoryUploadResult(
                acknowledgedIDs: [],
                remoteEntries: [],
                failures: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, SyncError.cloudUnavailable) })
            )
        }

        var acknowledgedIDs: Set<UUID> = []
        var remoteEntries: [SyncableHistoryEntry] = []
        var failures: [UUID: Error] = [:]

        // Resolve by record ID before saving so retries against an already
        // present CloudKit record are acknowledgements, not permanent conflicts.
        for entry in entries {
            do {
                let recordID = CKRecord.ID(
                    recordName: entry.id.uuidString,
                    zoneID: SyncConfiguration.zoneID
                )
                let existingRecord: CKRecord?
                do {
                    existingRecord = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    existingRecord = nil
                }

                if let existingRecord,
                   let remoteEntry = SyncRecord.entry(from: existingRecord),
                   remoteEntry.updatedAt >= entry.updatedAt {
                    acknowledgedIDs.insert(entry.id)
                    remoteEntries.append(remoteEntry)
                    continue
                }

                let record = SyncRecord.record(from: entry, existingRecord: existingRecord)
                _ = try await database.save(record)
                acknowledgedIDs.insert(entry.id)
            } catch {
                failures[entry.id] = error
            }
        }

        return HistoryUploadResult(
            acknowledgedIDs: acknowledgedIDs,
            remoteEntries: remoteEntries,
            failures: failures
        )
    }

    func delete(entryID: UUID) async throws {
        guard let database = SyncConfiguration.privateDatabase else {
            throw SyncError.cloudUnavailable
        }
        let recordID = CKRecord.ID(
            recordName: entryID.uuidString,
            zoneID: SyncConfiguration.zoneID
        )
        do {
            try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // An already absent record is a successful deletion reconciliation.
        }
    }

    private func makeFetchOperation(after tokenData: Data?) throws -> CKFetchRecordZoneChangesOperation {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        if let tokenData {
            config.previousServerChangeToken = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: tokenData
            )
        }

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [SyncConfiguration.zoneID],
            configurationsByRecordZoneID: [SyncConfiguration.zoneID: config]
        )
        // Consume one explicit page at a time. HistorySyncEngine advances the
        // token only after every page has been reconciled locally.
        operation.fetchAllChanges = false
        return operation
    }

    private func configureCallbacks(
        for operation: CKFetchRecordZoneChangesOperation,
        accumulator: HistoryFetchAccumulator
    ) {
        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record) where record.recordType == SyncConfiguration.recordType:
                if let entry = SyncRecord.entry(from: record) {
                    accumulator.append(change: .changed(entry))
                }
            case .success:
                // Other record types share the zone (for example encrypted
                // secrets) and belong to their own reconciliation subsystem.
                break
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            if recordType == SyncConfiguration.recordType,
               let id = UUID(uuidString: recordID.recordName) {
                accumulator.append(change: .deleted(id))
            }
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            accumulator.update(token: token)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (token, _, moreComing)):
                accumulator.update(token: token, moreComing: moreComing)
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
    }

    private func execute(
        _ operation: CKFetchRecordZoneChangesOperation,
        on database: CKDatabase
    ) async throws {
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
    }
}

private final class HistoryFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [HistoryRemoteChange] = []
    private var token: CKServerChangeToken?
    private var moreComing = false
    private var errors: [Error] = []

    func append(change: HistoryRemoteChange) {
        lock.withLock { changes.append(change) }
    }

    func append(error: Error) {
        lock.withLock { errors.append(error) }
    }

    func update(token: CKServerChangeToken?, moreComing: Bool? = nil) {
        lock.withLock {
            if let token {
                self.token = token
            }
            if let moreComing {
                self.moreComing = moreComing
            }
        }
    }

    func page() throws -> HistoryChangePage {
        try lock.withLock {
            if let error = errors.first {
                throw error
            }
            let tokenData = try token.map {
                try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            return HistoryChangePage(
                changes: changes,
                serverChangeTokenData: tokenData,
                moreComing: moreComing
            )
        }
    }
}
