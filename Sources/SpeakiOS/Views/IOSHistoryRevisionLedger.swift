#if os(iOS)
import Foundation

/// Revision bookkeeping for History's single ordered persistence worker.
///
/// Every operation is stamped with a revision when it is admitted, before the
/// caller suspends. A receipt may only act for a row (upload it, mark it
/// synced, delete it remotely) while no later admitted mutation, insertion or
/// clear has superseded the revision it carries.
struct IOSHistoryRevisionLedger {
    private(set) var revision: UInt64 = 0
    /// Revision of the snapshot currently on screen.
    private(set) var publishedRevision: UInt64 = 0
    private(set) var versions: [UUID: UInt64] = [:]
    private var durableVersions: [UUID: UInt64] = [:]
    private var latestMutation: [UUID: UInt64] = [:]
    private var latestClear: UInt64 = 0
    private var latestInsertion: [UUID: UInt64] = [:]

    mutating func admit(_ operation: IOSHistoryPersistence.Operation) -> UInt64 {
        revision += 1
        switch operation {
        case .upsert(let item), .remote(let item):
            latestMutation[item.id] = revision
            latestInsertion[item.id] = revision
        case .replaceIfUntouched(let item, _, _):
            latestMutation[item.id] = revision
        case let .processed(id, _, _, _), let .error(id, _), .remove(let id), .remoteDelete(let id):
            latestMutation[id] = revision
        case .clear: latestClear = revision
        case .load, .retry, .commit: break
        }
        return revision
    }

    /// Adopts a result's versions, unless an already published snapshot is newer.
    mutating func accept(_ result: IOSHistoryPersistence.Result) -> Bool {
        guard result.revision >= publishedRevision else { return false }
        publishedRevision = result.revision
        versions = result.versions
        durableVersions = result.durableVersions
        return true
    }

    /// No mutation of `id` was admitted after `receiptRevision`.
    func isUnchanged(_ id: UUID, since receiptRevision: UInt64) -> Bool {
        (latestMutation[id] ?? 0) <= receiptRevision
    }

    func isCurrent(_ id: UUID, version: UInt64, receiptRevision: UInt64) -> Bool {
        versions[id] == version && durableVersions[id] == version
            && isUnchanged(id, since: receiptRevision) && latestClear <= receiptRevision
    }

    func ownsMutation(_ id: UUID, result: IOSHistoryPersistence.Result) -> Bool {
        isUnchanged(id, since: result.revision) && latestClear <= result.revision
            && (publishedRevision <= result.revision || versions[id] == result.versions[id])
    }

    /// A newer re-insertion owns its notifications and CloudKit row.
    func ownsDeletion(
        _ id: UUID, result: IOSHistoryPersistence.Result, isVisible: @autoclosure () -> Bool
    ) -> Bool {
        (latestInsertion[id] ?? 0) <= result.revision
            && !(publishedRevision > result.revision && isVisible())
    }

    /// No row was inserted after `revision`, so a clear at it removed everything.
    func hasNoInsertion(after revision: UInt64) -> Bool {
        latestInsertion.values.allSatisfy { $0 <= revision }
    }
}

/// CloudKit acknowledgements History is still waiting to commit or consume.
struct IOSHistoryRemoteLedger {
    private var pendingVersions: [UUID: UInt64] = [:]
    /// The newest admitted remote revision not yet committed; zero when none.
    private(set) var uncommittedRevision: UInt64 = 0
    private var offeredVersions: [UUID: UInt64] = [:]
    private var directUploads: [UUID: Int] = [:]

    mutating func recordUncommitted(_ revision: UInt64) {
        uncommittedRevision = max(uncommittedRevision, revision)
    }

    mutating func recordAcknowledged(_ id: UUID, version: UInt64) {
        pendingVersions[id] = max(pendingVersions[id] ?? 0, version)
    }

    /// Settles a durable commit at `revision` that was started for `target`.
    /// Returns the acknowledgements pending before the commit, for the caller
    /// to check against the ledger.
    mutating func finishCommit(revision: UInt64, target: UInt64) -> [UUID: UInt64] {
        let pending = pendingVersions
        pendingVersions = pendingVersions.filter { $0.value > revision }
        if uncommittedRevision == target { uncommittedRevision = 0 }
        return pending
    }

    mutating func beginDirectUpload(_ id: UUID) {
        directUploads[id, default: 0] += 1
    }

    mutating func endDirectUpload(_ id: UUID) {
        let count = directUploads[id, default: 1] - 1
        directUploads[id] = count == 0 ? nil : count
    }

    /// Retains the first offer until its acknowledgement is consumed.
    mutating func offer(_ id: UUID, version: UInt64?) {
        if offeredVersions[id] == nil { offeredVersions[id] = version }
    }

    /// Offers among `ids` that no direct upload is racing.
    func unraced(offersAmong ids: Set<UUID>) -> [UUID: UInt64] {
        offeredVersions.filter { ids.contains($0.key) && directUploads[$0.key, default: 0] == 0 }
    }

    /// Consumes an offer that is still the one captured and still unraced.
    mutating func consume(_ id: UUID, version: UInt64) -> Bool {
        guard directUploads[id, default: 0] == 0, offeredVersions[id] == version else { return false }
        offeredVersions.removeValue(forKey: id)
        return true
    }
}
#endif
