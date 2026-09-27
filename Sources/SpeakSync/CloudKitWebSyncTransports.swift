import Foundation
import SpeakCore

/// History over CloudKit Web Services: the zone, record type, fields,
/// tombstones and conflict rule of `CloudKitHistorySyncTransport`, so Apple
/// devices and this client read and write the same records.
public final class CloudKitWebHistorySyncTransport: HistorySyncTransport, Sendable {
    private let client: CloudKitWebServicesClient
    private let session: CloudKitWebSession?

    /// Refuses to exist without the user's History consent.
    ///
    /// A reconciliation pass spans many calls. Bind it to `session`, the one
    /// `CloudKitWebSyncAccount.validate` confirmed, and every call fails with
    /// `sessionChanged` once that session ends, instead of sending the previous
    /// account's cursor or entries in the next one; pair it with a
    /// `CloudKitWebSessionFence` for the same session. Without a session, each
    /// call runs in the session current as it begins.
    public init(
        client: CloudKitWebServicesClient,
        consent: CloudKitWebSyncConsent,
        session: CloudKitWebSession? = nil
    ) throws {
        try consent.require(.history)
        self.client = client
        self.session = session
    }

    public func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        let page = try await client.fetchZoneChanges(
            zoneName: SyncSchema.zoneName,
            syncToken: try CloudKitWebSyncToken.string(from: tokenData),
            in: session
        )
        var changes: [HistoryRemoteChange] = []
        for result in page.records {
            switch result {
            case .failure(let error):
                // As with a native per-record fetch error, the page is not consumed.
                throw CloudKitWebServicesError.server(error)
            case .record(let record) where record.deleted:
                let deletion = HistoryRecordCodec.deletion(
                    recordName: record.recordName,
                    recordType: record.recordType
                )
                if let deletion {
                    changes.append(deletion)
                }
            case .record(let record):
                if let change = HistoryRecordCodec.change(from: record) {
                    changes.append(change)
                }
            }
        }
        return HistoryChangePage(
            changes: changes,
            serverChangeTokenData: CloudKitWebSyncToken.data(from: page.syncToken),
            moreComing: page.moreComing
        )
    }

    public func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        var result = HistoryUploadResult(acknowledgedIDs: [], remoteEntries: [], failures: [:])
        // Writes are built from this session's records, so they are sent in it or not at all.
        let session = await client.session(or: self.session)
        let names = entries.map { SyncSchema.History.recordName(for: $0.id) }
        let existing: [String: CloudKitWebLookupOutcome]
        do {
            existing = try await CloudKitWebRecordBatch.lookup(
                names,
                zoneName: SyncSchema.zoneName,
                client: client,
                session: session
            )
        } catch {
            for entry in entries { result.failures[entry.id] = error }
            return result
        }

        var writes: [(id: UUID, operation: CloudKitWebRecordOperation)] = []
        for entry in entries {
            do {
                if let operation = try write(for: entry, existing: existing, result: &result) {
                    writes.append((entry.id, operation))
                }
            } catch {
                result.failures[entry.id] = error
            }
        }

        let outcomes = await CloudKitWebRecordBatch.modify(
            writes,
            zoneName: SyncSchema.zoneName,
            client: client,
            session: session
        )
        for (id, outcome) in outcomes {
            switch outcome {
            case .success: result.acknowledgedIDs.insert(id)
            case .failure(let error): result.failures[id] = error
            }
        }
        return result
    }

    /// The write an entry needs, or `nil` when CloudKit's copy is acknowledged instead.
    private func write(
        for entry: SyncableHistoryEntry,
        existing: [String: CloudKitWebLookupOutcome],
        result: inout HistoryUploadResult
    ) throws -> CloudKitWebRecordOperation? {
        let name = SyncSchema.History.recordName(for: entry.id)
        let assignments = HistoryRecordCodec.assignments(for: entry)
        switch existing[name] ?? .failed(CloudKitWebRecordBatch.missingResult) {
        case .failed(let error):
            throw error
        case .absent:
            return try CloudKitWebRecordWrite.create(
                recordName: name,
                recordType: SyncSchema.History.recordType,
                assignments: assignments
            )
        case .found(let record):
            // Resolve by record ID before saving so retries against an
            // already present record are acknowledgements, not conflicts.
            if let remote = HistoryRecordCodec.entry(from: record),
               HistoryConflictPolicy.remoteWins(remote, over: entry) {
                result.acknowledgedIDs.insert(entry.id)
                result.remoteEntries.append(remote)
                return nil
            }
            return try CloudKitWebRecordWrite.update(
                existing: record,
                recordType: SyncSchema.History.recordType,
                assignments: assignments
            )
        }
    }

    public func delete(entryID: UUID) async throws {
        try await CloudKitWebRecordBatch.forceDelete(
            recordName: SyncSchema.History.recordName(for: entryID),
            zoneName: SyncSchema.zoneName,
            client: client,
            session: session
        )
    }
}

/// Compare Models rounds over CloudKit Web Services, with the revision,
/// tombstone and version rules of `CloudKitComparisonSyncTransport`.
public final class CloudKitWebComparisonSyncTransport: ComparisonSyncTransport, Sendable {
    private let client: CloudKitWebServicesClient

    public init(client: CloudKitWebServicesClient, consent: CloudKitWebSyncConsent) throws {
        try consent.require(.comparisonRounds)
        self.client = client
    }

    public func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage {
        let page = try await client.fetchZoneChanges(
            zoneName: SyncSchema.zoneName,
            syncToken: try CloudKitWebSyncToken.string(from: tokenData)
        )
        var changes: [ComparisonRemoteChange] = []
        for result in page.records {
            switch result {
            case .failure(let error):
                throw CloudKitWebServicesError.server(error)
            case .record(let record) where record.deleted:
                let deletion = ComparisonRecordCodec.deletion(
                    recordName: record.recordName,
                    recordType: record.recordType
                )
                if let deletion {
                    changes.append(deletion)
                }
            case .record(let record):
                // A round this build cannot read throws, so a compatible build replays the page.
                if let change = try ComparisonRecordCodec.change(from: record) {
                    changes.append(change)
                }
            }
        }
        return ComparisonChangePage(
            changes: changes,
            serverChangeTokenData: CloudKitWebSyncToken.data(from: page.syncToken),
            moreComing: page.moreComing
        )
    }

    public func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult {
        var result = ComparisonUploadResult()
        let session = await client.session()
        let names = revisions.map { SyncSchema.ComparisonRound.recordName(for: $0.id) }
        let existing: [String: CloudKitWebLookupOutcome]
        do {
            existing = try await CloudKitWebRecordBatch.lookup(
                names,
                zoneName: SyncSchema.zoneName,
                client: client,
                session: session
            )
        } catch {
            for revision in revisions { result.failures[revision.id] = error }
            return result
        }

        var writes: [(revision: ModelComparisonRevision, operation: CloudKitWebRecordOperation)] = []
        for revision in revisions {
            do {
                if let operation = try write(for: revision, existing: existing, remote: &result.remote) {
                    writes.append((revision, operation))
                }
            } catch {
                result.failures[revision.id] = error
            }
        }

        let outcomes = await CloudKitWebRecordBatch.modify(
            writes.map { ($0.revision.id, $0.operation) },
            zoneName: SyncSchema.zoneName,
            client: client,
            session: session
        )
        for (index, outcome) in outcomes.enumerated() {
            switch outcome.result {
            case .success: result.acknowledged.append(writes[index].revision)
            case .failure(let error): result.failures[outcome.id] = error
            }
        }
        return result
    }

    /// The write a revision needs, or `nil` when CloudKit's copy wins.
    private func write(
        for revision: ModelComparisonRevision,
        existing: [String: CloudKitWebLookupOutcome],
        remote: inout [ModelComparisonRevision]
    ) throws -> CloudKitWebRecordOperation? {
        let name = SyncSchema.ComparisonRound.recordName(for: revision.id)
        switch existing[name] ?? .failed(CloudKitWebRecordBatch.missingResult) {
        case .failed(let error):
            throw error
        case .absent:
            return try CloudKitWebRecordWrite.create(
                recordName: SyncSchema.ComparisonRound.recordName(for: revision.round?.id ?? revision.id),
                recordType: SyncSchema.ComparisonRound.recordType,
                assignments: try ComparisonRecordCodec.assignments(for: revision)
            )
        case .found(let record):
            let remoteRevision = try ComparisonRecordCodec.revision(from: record)
            if ComparisonConflictPolicy.remoteWins(remoteRevision, over: revision) {
                remote.append(remoteRevision)
                return nil
            }
            return try CloudKitWebRecordWrite.update(
                existing: record,
                recordType: SyncSchema.ComparisonRound.recordType,
                assignments: try ComparisonRecordCodec.assignments(for: revision)
            )
        }
    }
}

/// A web change-feed cursor is the server's opaque `syncToken`, stored as UTF-8.
enum CloudKitWebSyncToken {
    static func string(from data: Data?) throws -> String? {
        guard let data else { return nil }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CloudKitWebServicesError.invalidChangeToken
        }
        return token
    }

    static func data(from token: String?) -> Data? {
        guard let token, !token.isEmpty else { return nil }
        return Data(token.utf8)
    }
}
