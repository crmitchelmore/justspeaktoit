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
    /// Local entries that are not currently acknowledged by CloudKit.
    func pendingEntries() async -> [SyncableHistoryEntry]
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

/// The History reconciliation every client runs: walk the change feed one page
/// at a time — coalesce the page to one final event per record, apply it,
/// commit it through the store and only then save that page's cursor, before
/// fetching the next — then upload pending entries and acknowledge only what
/// CloudKit confirmed.
///
/// A pass therefore holds one page, however long the feed, and what it has
/// committed survives a failure or stop on a later page: the next pass
/// resumes from the last saved cursor. Every cursor a page returns is a valid
/// resume point (CloudKit's `moreComing` contract), and none is saved ahead
/// of a change that was not committed. Applying pages in feed order reaches
/// the same states as syncing between them would, which stores already handle.
///
/// A coordinator is confined to one isolation domain. Each method runs on the
/// caller's actor (`#isolation`), so the Apple engine keeps executing on the
/// main actor while a desktop host drives its own instance from its own actor.
/// Never share one coordinator between actors.
public final class HistorySyncCoordinator {
    /// An upper bound on back-to-back passes, so a burst of triggers cannot
    /// keep one `sync` call running indefinitely. A trigger that arrives
    /// after the cap simply starts the next `sync`.
    public static let maxCoalescedPasses = 3

    public private(set) var status: HistorySyncStatus

    private let transport: any HistorySyncTransport
    private let tokenStore: any SyncChangeTokenStore
    private let observer: (any HistorySyncStatusObserver)?
    private let events: (@Sendable (HistorySyncEvent) -> Void)?
    private let now: @Sendable () -> Date
    let fence: (any HistorySyncPassFence)?
    /// A trigger observed while a pass was already running.
    private var followUpRequested = false

    /// `fence` admits each pass's account-bound work; see `HistorySyncPassFence`.
    public init(
        transport: any HistorySyncTransport,
        tokenStore: any SyncChangeTokenStore,
        cloudAvailable: Bool,
        observer: (any HistorySyncStatusObserver)? = nil,
        events: (@Sendable (HistorySyncEvent) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        fence: (any HistorySyncPassFence)? = nil
    ) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.observer = observer
        self.events = events
        self.now = now
        self.fence = fence
        status = HistorySyncStatus(isCloudAvailable: cloudAvailable)
    }

    /// Records the host's account probe. Sync refuses to run while unavailable.
    public func updateCloudAvailability(
        _ isAvailable: Bool,
        error: Error?,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        await set(\.isCloudAvailable, isAvailable, .isCloudAvailable, isolation: isolation)
        await set(\.error, error, .error, isolation: isolation)
    }

    /// Runs a complete fetch, reconciliation, and upload pass.
    ///
    /// A trigger that arrives while a pass is running is not dropped. The
    /// change it is about may already be behind the running fetch's cursor —
    /// a push notification for exactly that record, consumed and never
    /// reconciled, is how a device stays stale until some unrelated later sync
    /// — so it is remembered and a follow-up pass runs when this one ends.
    /// A `nil` store fails the call with `SyncError.delegateUnavailable`.
    public func sync(
        store: (any HistorySyncStore)?,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        let pendingCount = await store?.pendingEntries().count ?? 0
        await set(\.pendingUploadCount, pendingCount, .pendingUploadCount, isolation: isolation)
        await set(\.pendingDownloadCount, 0, .pendingDownloadCount, isolation: isolation)

        guard status.isCloudAvailable else {
            await set(\.error, SyncError.cloudUnavailable, .error, isolation: isolation)
            events?(.syncRequestedWhileCloudUnavailable)
            return
        }
        guard !status.isSyncing else {
            followUpRequested = true
            events?(.followUpQueued)
            return
        }
        guard let store else {
            await set(\.error, SyncError.delegateUnavailable, .error, isolation: isolation)
            return
        }

        // Set before the first suspension so a re-entrant trigger queues a
        // follow-up instead of starting a concurrent pass.
        await set(\.isSyncing, true, .isSyncing, isolation: isolation)
        await set(\.error, nil, .error, isolation: isolation)

        var passes = 0
        repeat {
            followUpRequested = false
            await runReconciliationPass(store: store, isolation: isolation)
            passes += 1
        } while followUpRequested && passes < Self.maxCoalescedPasses

        await set(\.isSyncing, false, .isSyncing, isolation: isolation)
    }

    /// Uploads a single entry and acknowledges it only after CloudKit confirms it.
    public func upload(
        entry: SyncableHistoryEntry,
        store: (any HistorySyncStore)?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        guard status.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }
        // Without a store the acknowledgement cannot be persisted, so the
        // entry would upload again after relaunch. Fail before touching the
        // transport and leave the entry pending.
        guard let store else {
            let syncError = SyncError.delegateUnavailable
            await set(\.error, syncError, .error, isolation: isolation)
            throw syncError
        }
        try await admitted(isolation: isolation) {}
        let result = await transport.upload(entries: [entry])
        try await applyUploadResult(result, store: store, isolation: isolation)
        let pendingCount = await store.pendingEntries().count
        await set(\.pendingUploadCount, pendingCount, .pendingUploadCount, isolation: isolation)
        if let error = result.failures[entry.id] {
            let syncError = SyncError.cloudKit(error)
            await set(\.error, syncError, .error, isolation: isolation)
            throw syncError
        }
        await set(\.error, nil, .error, isolation: isolation)
        events?(.uploaded(entry.id))
    }

    public func delete(entryID: UUID, isolation: isolated (any Actor)? = #isolation) async throws {
        guard status.isCloudAvailable else {
            throw SyncError.cloudUnavailable
        }
        try await admitted(isolation: isolation) {}
        do {
            try await transport.delete(entryID: entryID)
            events?(.deleted(entryID))
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    private func runReconciliationPass(
        store: any HistorySyncStore,
        isolation: isolated (any Actor)?
    ) async {
        do {
            try await fetchRemoteChanges(store: store, isolation: isolation)
            try await uploadPendingEntries(store: store, isolation: isolation)
            await set(\.pendingDownloadCount, 0, .pendingDownloadCount, isolation: isolation)
            let pendingCount = await store.pendingEntries().count
            await set(\.pendingUploadCount, pendingCount, .pendingUploadCount, isolation: isolation)
            guard status.pendingUploadCount == 0 else {
                throw SyncError.reconciliationIncomplete(status.pendingUploadCount)
            }
            await set(\.lastSyncTime, now(), .lastSyncTime, isolation: isolation)
            events?(.passCompleted)
        } catch {
            await set(\.error, error, .error, isolation: isolation)
            let pendingCount = await store.pendingEntries().count
            await set(\.pendingUploadCount, pendingCount, .pendingUploadCount, isolation: isolation)
            events?(.passFailed(error))
        }
    }

    private func fetchRemoteChanges(
        store: any HistorySyncStore,
        isolation: isolated (any Actor)?
    ) async throws {
        var tokenData = try await admitted(isolation: isolation) { try await tokenStore.loadChangeToken() }
        var reconciled = 0

        while true {
            try await admitted(isolation: isolation) {}
            let page = try await transport.fetchChanges(after: tokenData)
            await set(\.pendingDownloadCount, page.changes.count, .pendingDownloadCount, isolation: isolation)

            // Checked before anything on the page is applied: a page that
            // cannot advance the cursor would be fetched again forever.
            let pageToken = page.serverChangeTokenData
            guard !page.moreComing || (pageToken != nil && pageToken != tokenData) else {
                throw SyncError.invalidChangePage
            }

            reconciled += try await applyAndCommit(page, store: store, isolation: isolation)
            if let pageToken {
                try await admitted(isolation: isolation) { try await tokenStore.saveChangeToken(pageToken) }
                tokenData = pageToken
            }
            guard page.moreComing else { break }
        }

        events?(.reconciledRemoteChanges(reconciled))
    }

    /// Applies one page's final events and commits them through the store;
    /// returns how many were applied. The caller saves the page's cursor only
    /// after this returns.
    private func applyAndCommit(
        _ page: HistoryChangePage,
        store: any HistorySyncStore,
        isolation: isolated (any Actor)?
    ) async throws -> Int {
        let changes = HistoryChangeReconciler.coalesced(page.changes)
        await set(\.pendingDownloadCount, changes.count, .pendingDownloadCount, isolation: isolation)
        for change in changes {
            try await admitted(isolation: isolation) {
                switch change {
                case .changed(let entry):
                    await store.didReceiveRemoteEntry(entry)
                case .deleted(let id):
                    await store.didDeleteRemoteEntry(id: id)
                }
            }
            await set(\.pendingDownloadCount, status.pendingDownloadCount - 1, .pendingDownloadCount,
                      isolation: isolation)
        }
        try await store.persistRemoteChanges()
        return changes.count
    }

    private func uploadPendingEntries(
        store: any HistorySyncStore,
        isolation: isolated (any Actor)?
    ) async throws {
        while true {
            let pending = await store.pendingEntries()
            await set(\.pendingUploadCount, pending.count, .pendingUploadCount, isolation: isolation)
            guard !pending.isEmpty else { return }

            let batch = Array(pending.prefix(SyncSchema.batchSize))
            try await admitted(isolation: isolation) {}
            let result = await transport.upload(entries: batch)
            try await applyUploadResult(result, store: store, isolation: isolation)
            let remaining = await store.pendingEntries().count
            await set(\.pendingUploadCount, remaining, .pendingUploadCount, isolation: isolation)

            if !result.failures.isEmpty {
                throw SyncError.partialUploadFailure(result.failures.count)
            }
            guard status.pendingUploadCount < pending.count else {
                throw SyncError.reconciliationIncomplete(status.pendingUploadCount)
            }
        }
    }

    private func applyUploadResult(
        _ result: HistoryUploadResult,
        store: any HistorySyncStore,
        isolation: isolated (any Actor)?
    ) async throws {
        try await admitted(isolation: isolation) {
            for entry in result.remoteEntries {
                await store.didReceiveRemoteEntry(entry)
            }
        }
        try await store.persistRemoteChanges()
        guard !result.acknowledgedIDs.isEmpty else { return }
        try await admitted(isolation: isolation) {
            await store.didAcknowledgeSyncedEntries(ids: result.acknowledgedIDs)
        }
    }

    private func set<Value>(
        _ keyPath: WritableKeyPath<HistorySyncStatus, Value>,
        _ value: Value,
        _ field: HistorySyncStatus.Field,
        isolation: isolated (any Actor)?
    ) async {
        status[keyPath: keyPath] = value
        await observer?.historySync(status, didChange: field)
    }
}
