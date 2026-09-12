import CloudKit
import Foundation
import SpeakCore

/// CloudKit-backed transport for comparison rounds. Shares the History zone
/// but walks it with its own change token and ignores every other record
/// type (History entries, encrypted secrets), which their own engines own.
@MainActor
final class CloudKitComparisonSyncTransport: ComparisonSyncTransport {
    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage {
        guard let database = SyncConfiguration.privateDatabase else { throw SyncError.cloudUnavailable }
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
        operation.fetchAllChanges = false
        let accumulator = ComparisonFetchAccumulator()
        configureCallbacks(for: operation, accumulator: accumulator)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        return try accumulator.page()
    }

    private func configureCallbacks(
        for operation: CKFetchRecordZoneChangesOperation,
        accumulator: ComparisonFetchAccumulator
    ) {
        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                if let round = ComparisonSyncRecord.round(from: record) {
                    accumulator.append(change: .changed(round))
                }
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            if recordType == ComparisonSyncRecord.recordType,
               let id = ComparisonSyncRecord.roundID(fromRecordName: recordID.recordName) {
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

    func upload(rounds: [ModelComparisonRound]) async -> ComparisonUploadResult {
        guard let database = SyncConfiguration.privateDatabase else {
            return ComparisonUploadResult(
                acknowledgedIDs: [],
                remoteRounds: [],
                failures: Dictionary(uniqueKeysWithValues: rounds.map { ($0.id, SyncError.cloudUnavailable) })
            )
        }
        var result = ComparisonUploadResult(acknowledgedIDs: [], remoteRounds: [], failures: [:])
        for round in rounds {
            do {
                let recordID = ComparisonSyncRecord.recordID(for: round.id)
                let existing: CKRecord?
                do {
                    existing = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    existing = nil
                }
                if let existing,
                   let remote = ComparisonSyncRecord.round(from: existing),
                   remote.updatedAt > round.updatedAt {
                    result.acknowledgedIDs.insert(round.id)
                    result.remoteRounds.append(remote)
                    continue
                }
                let record = try ComparisonSyncRecord.record(from: round, existingRecord: existing)
                _ = try await database.save(record)
                result.acknowledgedIDs.insert(round.id)
            } catch {
                result.failures[round.id] = error
            }
        }
        return result
    }

    func delete(roundID: UUID) async throws {
        guard let database = SyncConfiguration.privateDatabase else { throw SyncError.cloudUnavailable }
        do {
            try await database.deleteRecord(withID: ComparisonSyncRecord.recordID(for: roundID))
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone: the deletion is reconciled.
        }
    }
}

private final class ComparisonFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [ComparisonRemoteChange] = []
    private var token: CKServerChangeToken?
    private var moreComing = false
    private var errors: [Error] = []

    func append(change: ComparisonRemoteChange) {
        lock.withLock { changes.append(change) }
    }

    func append(error: Error) {
        lock.withLock { errors.append(error) }
    }

    func update(token: CKServerChangeToken?, moreComing: Bool? = nil) {
        lock.withLock {
            if let token { self.token = token }
            if let moreComing { self.moreComing = moreComing }
        }
    }

    func page() throws -> ComparisonChangePage {
        try lock.withLock {
            if let error = errors.first { throw error }
            let tokenData = try token.map {
                try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            return ComparisonChangePage(changes: changes, serverChangeTokenData: tokenData, moreComing: moreComing)
        }
    }
}
