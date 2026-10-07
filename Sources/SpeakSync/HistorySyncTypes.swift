import Foundation

public enum HistoryRemoteChange {
    case changed(SyncableHistoryEntry)
    case deleted(UUID)

    public var id: UUID {
        switch self {
        case .changed(let entry):
            return entry.id
        case .deleted(let id):
            return id
        }
    }
}

public struct HistoryChangePage {
    public var changes: [HistoryRemoteChange]
    public var serverChangeTokenData: Data?
    public var moreComing: Bool

    public init(changes: [HistoryRemoteChange], serverChangeTokenData: Data?, moreComing: Bool) {
        self.changes = changes
        self.serverChangeTokenData = serverChangeTokenData
        self.moreComing = moreComing
    }
}

public struct HistoryUploadResult {
    public var acknowledgedIDs: Set<UUID>
    public var remoteEntries: [SyncableHistoryEntry]
    public var failures: [UUID: Error]

    public init(acknowledgedIDs: Set<UUID>, remoteEntries: [SyncableHistoryEntry], failures: [UUID: Error]) {
        self.acknowledgedIDs = acknowledgedIDs
        self.remoteEntries = remoteEntries
        self.failures = failures
    }

    public static func success(ids: Set<UUID>) -> HistoryUploadResult {
        HistoryUploadResult(acknowledgedIDs: ids, remoteEntries: [], failures: [:])
    }
}

/// One History change feed and record store: the native CloudKit adapter or
/// CloudKit Web Services. Implementations report per-entry failures in the
/// upload result instead of throwing, and resolve by record ID before saving
/// so a retry against an already present record is an acknowledgement.
public protocol HistorySyncTransport: AnyObject {
    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage
    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult
    func delete(entryID: UUID) async throws
}

/// Where reconciled History changes land. Requirements are asynchronous so an
/// implementation can live on whichever actor owns its store: the Apple engine
/// adapts its main-actor `HistorySyncDelegate`, and a desktop host implements
/// this directly without a UI run loop.
public protocol HistorySyncStore: AnyObject {
    /// Local entries that are not currently acknowledged by CloudKit. Throws
    /// when History cannot be read, so the pass fails rather than finding none.
    func pendingEntries() async throws -> [SyncableHistoryEntry]
    /// Reconcile a new, duplicate, or updated entry from CloudKit.
    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async
    /// Reconcile a CloudKit tombstone.
    func didDeleteRemoteEntry(id: UUID) async
    /// Record IDs that CloudKit has acknowledged.
    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async
    /// Commit the remote changes reconciled since the last commit: one page of
    /// the change feed, or the server copies an upload returned. That page's
    /// change token is saved, and that upload's acknowledgements recorded,
    /// only after this returns, so throwing replays the same changes on the
    /// next pass. A store that could not apply one of those changes throws
    /// here for the same reason.
    func persistRemoteChanges() async throws
}

/// A snapshot of History sync progress for a host's UI.
public struct HistorySyncStatus {
    public enum Field: Sendable {
        case isSyncing
        case lastSyncTime
        case error
        case pendingUploadCount
        case pendingDownloadCount
        case isCloudAvailable
    }

    public var isSyncing = false
    public var lastSyncTime: Date?
    public var error: Error?
    public var pendingUploadCount = 0
    public var pendingDownloadCount = 0
    public var isCloudAvailable = false

    public init(isCloudAvailable: Bool = false) {
        self.isCloudAvailable = isCloudAvailable
    }
}

/// Receives each status assignment in the order the coordinator makes it.
public protocol HistorySyncStatusObserver: AnyObject {
    func historySync(_ status: HistorySyncStatus, didChange field: HistorySyncStatus.Field) async
}

/// Diagnostics a host may log. Payloads carry no transcript text.
public enum HistorySyncEvent {
    case syncRequestedWhileCloudUnavailable
    case followUpQueued
    case passCompleted
    case passFailed(Error)
    case uploaded(UUID)
    case deleted(UUID)
    case reconciledRemoteChanges(Int)
}
