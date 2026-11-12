import CloudKit
import Foundation

/// One page of changes from the shared sync zone, walked with a caller-owned
/// change token. History and comparison rounds share the zone; each decodes
/// only its own record types and ignores the rest, which other engines own.
struct CloudKitZoneChangePage<Change> {
    var changes: [Change]
    var serverChangeTokenData: Data?
    var moreComing: Bool
}

@MainActor
enum CloudKitZoneChangeFetch {
    /// Fetches one page after `tokenData`. `change` returns nil for a record
    /// type it does not own; an error it throws, like any record or zone
    /// error, fails the page, so the token is not advanced past it.
    static func page<Change>(
        after tokenData: Data?, in database: CKDatabase,
        change: @escaping @Sendable (CKRecord) throws -> Change?,
        deletion: @escaping @Sendable (_ recordID: CKRecord.ID, _ recordType: CKRecord.RecordType) -> Change?
    ) async throws -> CloudKitZoneChangePage<Change> {
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
        // Consume one explicit page at a time. The shared coordinator saves
        // each page's token only after that page has been committed locally.
        operation.fetchAllChanges = false
        let accumulator = Accumulator<Change>()
        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                do {
                    if let decoded = try change(record) { accumulator.append(change: decoded) }
                } catch {
                    accumulator.append(error: error)
                }
            case .failure(let error):
                accumulator.append(error: error)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, recordType in
            if let decoded = deletion(recordID, recordType) { accumulator.append(change: decoded) }
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

    /// The saved record with `recordID`, or nil when the zone has none.
    static func existingRecord(_ recordID: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private final class Accumulator<Change>: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [Change] = []
        private var token: CKServerChangeToken?
        private var moreComing = false
        private var errors: [Error] = []

        func append(change: Change) {
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

        func page() throws -> CloudKitZoneChangePage<Change> {
            try lock.withLock {
                if let error = errors.first { throw error }
                let tokenData = try token.map {
                    try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                return CloudKitZoneChangePage(
                    changes: changes, serverChangeTokenData: tokenData, moreComing: moreComing
                )
            }
        }
    }
}
