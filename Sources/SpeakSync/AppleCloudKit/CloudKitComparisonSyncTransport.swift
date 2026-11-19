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
        let page = try await CloudKitZoneChangeFetch.page(
            after: tokenData, in: database,
            // An unknown version throws, so the page is not consumed: a compatible build must replay it.
            change: { try ComparisonRecordCodec.change(from: CloudKitRecordFields($0)) },
            deletion: { ComparisonRecordCodec.deletion(recordName: $0.recordName, recordType: $1) }
        )
        return ComparisonChangePage(
            changes: page.changes, serverChangeTokenData: page.serverChangeTokenData, moreComing: page.moreComing
        )
    }

    func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult {
        var result = ComparisonUploadResult()
        guard let database = SyncConfiguration.privateDatabase else {
            for revision in revisions { result.failures[revision.id] = SyncError.cloudUnavailable }
            return result
        }
        for revision in revisions {
            do {
                let recordID = ComparisonSyncRecord.recordID(for: revision.id)
                let existing = try await CloudKitZoneChangeFetch.existingRecord(recordID, in: database)
                if let existing {
                    let remote = try ComparisonSyncRecord.revision(from: existing)
                    if ComparisonConflictPolicy.remoteWins(remote, over: revision) {
                        result.remote.append(remote)
                        continue
                    }
                }
                let record = try ComparisonSyncRecord.record(from: revision, existingRecord: existing)
                _ = try await database.save(record)
                result.acknowledged.append(revision)
            } catch {
                result.failures[revision.id] = error
            }
        }
        return result
    }
}
