import CloudKit
import Foundation

@MainActor
final class CloudKitHistorySyncTransport: HistorySyncTransport {
    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        guard let database = SyncConfiguration.privateDatabase else {
            throw SyncError.cloudUnavailable
        }
        let page = try await CloudKitZoneChangeFetch.page(
            after: tokenData, in: database,
            // Other record types share the zone (for example encrypted
            // secrets) and belong to their own reconciliation subsystem.
            change: { HistoryRecordCodec.change(from: CloudKitRecordFields($0)) },
            deletion: { HistoryRecordCodec.deletion(recordName: $0.recordName, recordType: $1) }
        )
        return HistoryChangePage(
            changes: page.changes, serverChangeTokenData: page.serverChangeTokenData, moreComing: page.moreComing
        )
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
                let existingRecord = try await CloudKitZoneChangeFetch.existingRecord(recordID, in: database)

                if let existingRecord,
                   let remoteEntry = SyncRecord.entry(from: existingRecord),
                   HistoryConflictPolicy.remoteWins(remoteEntry, over: entry) {
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
}
