import Foundation

/// A looked-up record, its absence, or a per-record failure.
enum CloudKitWebLookupOutcome {
    case found(CloudKitWebRecord)
    case absent
    case failed(Error)
}

/// Request-sized batches with per-record results, matching the native
/// transports' one-save-per-record outcomes.
enum CloudKitWebRecordBatch {
    static let missingResult = CloudKitWebServicesError.invalidResponse(
        "CloudKit returned no result for a requested record."
    )

    /// Looks records up by name. A chunk whose response exceeds the client's
    /// limit is split in half and retried, down to a single record.
    static func lookup(
        _ names: [String],
        zoneName: String,
        client: CloudKitWebServicesClient,
        session: CloudKitWebSession
    ) async throws -> [String: CloudKitWebLookupOutcome] {
        var outcomes: [String: CloudKitWebLookupOutcome] = [:]
        var pending = chunks(of: names)
        while let chunk = pending.popLast() {
            do {
                let results = try await client.lookupRecords(zoneName: zoneName, recordNames: chunk, in: session)
                for (name, result) in attribute(results, to: chunk) {
                    outcomes[name] = lookupOutcome(for: result)
                }
            } catch CloudKitWebServicesError.transport(.responseTooLarge) where chunk.count > 1 {
                let middle = chunk.count / 2
                pending.append(Array(chunk[..<middle]))
                pending.append(Array(chunk[middle...]))
            }
        }
        return outcomes
    }

    /// Sends writes and pairs each with its own result, in write order. A
    /// request that fails as a whole fails every write it carried.
    static func modify(
        _ writes: [(id: UUID, operation: CloudKitWebRecordOperation)],
        zoneName: String,
        client: CloudKitWebServicesClient,
        session: CloudKitWebSession
    ) async -> [(id: UUID, result: Result<Void, Error>)] {
        var outcomes: [(id: UUID, result: Result<Void, Error>)] = []
        for chunk in chunks(of: writes) {
            let names = chunk.map(\.operation.record.recordName)
            do {
                let results = try await client.modifyRecords(
                    zoneName: zoneName,
                    operations: chunk.map(\.operation),
                    in: session
                )
                let attributed = attribute(results, to: names)
                for write in chunk {
                    let result = attributed[write.operation.record.recordName]
                    outcomes.append((write.id, writeOutcome(for: result)))
                }
            } catch {
                outcomes += chunk.map { ($0.id, .failure(error)) }
            }
        }
        return outcomes
    }

    /// Deletes one record; an already absent record is a successful deletion.
    static func forceDelete(recordName: String, zoneName: String, client: CloudKitWebServicesClient) async throws {
        let operation = CloudKitWebRecordWrite.forceDelete(recordName: recordName)
        let results = try await client.modifyRecords(zoneName: zoneName, operations: [operation], in: nil)
        guard let result = attribute(results, to: [recordName])[recordName] else { throw missingResult }
        if case .failure(let error) = result, error.code != .notFound {
            throw CloudKitWebServicesError.server(error)
        }
    }

    /// Matches results to requested names by the name each result carries, or by
    /// position when an error dictionary omits it. Unrequested names are ignored.
    static func attribute(
        _ results: [CloudKitWebRecordResult],
        to names: [String]
    ) -> [String: CloudKitWebRecordResult] {
        let requested = Set(names)
        var attributed: [String: CloudKitWebRecordResult] = [:]
        for (index, result) in results.enumerated() {
            let name = result.recordName ?? (names.indices.contains(index) ? names[index] : nil)
            if let name, requested.contains(name) {
                attributed[name] = result
            }
        }
        return attributed
    }

    private static func lookupOutcome(for result: CloudKitWebRecordResult) -> CloudKitWebLookupOutcome {
        switch result {
        case .record(let record):
            return record.deleted ? .absent : .found(record)
        case .failure(let error) where error.code == .notFound:
            return .absent
        case .failure(let error):
            return .failed(CloudKitWebServicesError.server(error))
        }
    }

    private static func writeOutcome(for result: CloudKitWebRecordResult?) -> Result<Void, Error> {
        switch result {
        case .record?:
            return .success(())
        case .failure(let error)?:
            return .failure(CloudKitWebServicesError.server(error))
        case nil:
            return .failure(missingResult)
        }
    }

    private static func chunks<Element>(of elements: [Element]) -> [[Element]] {
        let size = CloudKitWebServicesLimits.maximumOperationsPerRequest
        return stride(from: 0, to: elements.count, by: size).map {
            Array(elements[$0..<min($0 + size, elements.count)])
        }
    }
}

/// Remembers which iCloud user a client's cursors belong to.
public protocol CloudKitWebSyncAccountStore: AnyObject {
    func boundAccountRecordName() async throws -> String?
    func bindAccount(recordName: String) async throws
}

public enum CloudKitWebSyncAccountBinding: Equatable, Sendable {
    case unchanged
    /// No account was bound yet; this client syncs from the beginning.
    case firstUse
    /// A different iCloud user signed in. Account-bound cursors were cleared;
    /// the host must also forget which local entries it had acknowledged, so
    /// they upload to the new account instead of being treated as synced.
    case changed
}

public enum CloudKitWebSyncAccount {
    /// Confirms the signed-in iCloud user before a sync, as `CloudKitKeySync`
    /// does natively. Cursors recorded for another user are cleared before the
    /// new user is bound, so an interruption repeats the reset.
    public static func validate(
        client: CloudKitWebServicesClient,
        store: any CloudKitWebSyncAccountStore,
        accountBoundCursors: [any SyncChangeTokenStore]
    ) async throws -> CloudKitWebSyncAccountBinding {
        let session = await client.session()
        let current = try await client.currentUserRecordName(in: session)
        let previous = try await store.boundAccountRecordName()
        // The identity must still be the signed-in one when cursors are reset
        // and rebound; a sign-in in between restarts the check next time.
        guard await client.session() == session else { throw CloudKitWebServicesError.sessionChanged }
        guard previous != current else { return .unchanged }
        for cursor in accountBoundCursors {
            try await cursor.clearChangeToken()
        }
        try await store.bindAccount(recordName: current)
        return previous == nil ? .firstUse : .changed
    }

    /// Creates the shared zone when the account has none, the same idempotent
    /// step the Apple engines take on first launch. It needs consent for the
    /// feature that is about to sync, and never alters the CloudKit schema.
    public static func ensureSyncZone(
        for feature: CloudKitWebSyncFeature,
        client: CloudKitWebServicesClient,
        consent: CloudKitWebSyncConsent
    ) async throws {
        try consent.require(feature)
        try await client.createZone(zoneName: SyncSchema.zoneName, in: nil)
    }
}
