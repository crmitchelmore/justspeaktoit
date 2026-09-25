import Foundation
import SpeakCore

@testable import SpeakSync

/// A desktop-style host: owns a coordinator on its own actor, with no main actor.
actor HistoryHost {
    let coordinator: HistorySyncCoordinator

    init(
        transport: any HistorySyncTransport,
        tokens: any SyncChangeTokenStore,
        cloudAvailable: Bool = true,
        observer: (any HistorySyncStatusObserver)? = nil,
        fence: (any HistorySyncPassFence)? = nil
    ) {
        coordinator = HistorySyncCoordinator(
            transport: transport,
            tokenStore: tokens,
            cloudAvailable: cloudAvailable,
            observer: observer,
            now: { Date(timeIntervalSince1970: 42) },
            fence: fence
        )
    }

    func sync(store: (any HistorySyncStore)?) async {
        await coordinator.sync(store: store)
    }

    func upload(_ entry: SyncableHistoryEntry, store: (any HistorySyncStore)?) async throws {
        try await coordinator.upload(entry: entry, store: store)
    }

    func delete(_ id: UUID) async throws {
        try await coordinator.delete(entryID: id)
    }

    var errorDescription: String? { coordinator.status.error.map { String(describing: $0) } }
    var lastSyncTime: Date? { coordinator.status.lastSyncTime }
    var pendingUploadCount: Int { coordinator.status.pendingUploadCount }
    var pendingDownloadCount: Int { coordinator.status.pendingDownloadCount }
    var isSyncing: Bool { coordinator.status.isSyncing }
}

/// Scripted History feed and uploads, like the Apple engine tests' fake.
actor FakeHistoryTransport: HistorySyncTransport {
    private var pages: [HistoryChangePage]
    private var uploads: [HistoryUploadResult]
    private(set) var requestedTokens: [Data?] = []
    private(set) var uploadedBatches: [[UUID]] = []
    private(set) var deleted: [UUID] = []
    private var onFetch: (@Sendable () async -> Void)?
    private var deleteError: Error?
    private var fetchLog: FakeHistoryStore?

    init(pages: [HistoryChangePage], uploads: [HistoryUploadResult] = []) {
        self.pages = pages
        self.uploads = uploads
    }

    func setOnFetch(_ action: @escaping @Sendable () async -> Void) {
        onFetch = action
    }

    func failDeletes(with error: Error) {
        deleteError = error
    }

    /// Notes each fetch in `store`'s log, in order with what the store applies.
    func logFetches(into store: FakeHistoryStore) {
        fetchLog = store
    }

    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        requestedTokens.append(tokenData)
        await fetchLog?.note("fetch")
        if let action = onFetch {
            onFetch = nil
            await action()
        }
        guard !pages.isEmpty else {
            return HistoryChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)
        }
        return pages.removeFirst()
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        uploadedBatches.append(entries.map(\.id))
        return uploads.isEmpty ? .success(ids: Set(entries.map(\.id))) : uploads.removeFirst()
    }

    func delete(entryID: UUID) async throws {
        if let deleteError { throw deleteError }
        deleted.append(entryID)
    }
}

/// A store on its own actor, recording what reconciliation asked of it.
actor FakeHistoryStore: HistorySyncStore {
    private var entriesByID: [UUID: SyncableHistoryEntry]
    private(set) var acknowledgedIDs: Set<UUID> = []
    private(set) var received: [SyncableHistoryEntry] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var log: [String] = []
    private var failsCommits = false
    private let acknowledges: Bool

    init(entries: [SyncableHistoryEntry], acknowledges: Bool = true) {
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        self.acknowledges = acknowledges
    }

    func failCommits(_ fails: Bool) {
        failsCommits = fails
    }

    /// Entries the store holds now, whether or not they are acknowledged.
    var storedIDs: Set<UUID> { Set(entriesByID.keys) }

    func pendingEntries() async -> [SyncableHistoryEntry] {
        entriesByID.values.filter { !acknowledgedIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        received.append(entry)
        log.append("receive")
        if entry.updatedAt >= (entriesByID[entry.id]?.updatedAt ?? .distantPast) {
            entriesByID[entry.id] = entry
            if acknowledges { acknowledgedIDs.insert(entry.id) }
        }
    }

    func didDeleteRemoteEntry(id: UUID) async {
        deletedIDs.append(id)
        log.append("delete")
        entriesByID.removeValue(forKey: id)
        acknowledgedIDs.remove(id)
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        if acknowledges { acknowledgedIDs.formUnion(ids.intersection(Set(entriesByID.keys))) }
    }

    func persistRemoteChanges() async throws {
        log.append("commit")
        if failsCommits { throw CloudKitWebTestError.injected }
    }
}

/// Records every status assignment in order.
actor StatusRecorder: HistorySyncStatusObserver {
    private(set) var fields: [HistorySyncStatus.Field] = []

    func historySync(_ status: HistorySyncStatus, didChange field: HistorySyncStatus.Field) async {
        fields.append(field)
    }
}

/// Holds the pass inside the first status assignment that matches, as a slow
/// window would, so a test can change the session between pages or batches.
actor HeldStatusObserver: HistorySyncStatusObserver {
    /// The pass stopped syncing without reaching the hold.
    struct NeverHeld: Error {}

    private let predicate: @Sendable (HistorySyncStatus, HistorySyncStatus.Field) -> Bool
    private var hasHeld = false
    private var hasStopped = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Error>] = []

    init(holdWhen predicate: @escaping @Sendable (HistorySyncStatus, HistorySyncStatus.Field) -> Bool) {
        self.predicate = predicate
    }

    var isHolding: Bool { waiter != nil }

    /// Returns once the pass is held, however long its work before the hold
    /// takes: its arrival ends the wait, not a count of scheduler turns.
    /// Throws `NeverHeld` if the pass stops syncing first.
    func waitUntilHolding() async throws {
        guard waiter == nil else { return }
        guard !hasStopped else { throw NeverHeld() }
        try await withCheckedThrowingContinuation { (arrival: CheckedContinuation<Void, Error>) in
            arrivals.append(arrival)
        }
    }

    func historySync(_ status: HistorySyncStatus, didChange field: HistorySyncStatus.Field) async {
        if field == .isSyncing, !status.isSyncing {
            hasStopped = true
            resolveArrivals(.failure(NeverHeld()))
        }
        guard !hasHeld, predicate(status, field) else { return }
        hasHeld = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            resolveArrivals(.success(()))
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    private func resolveArrivals(_ outcome: Result<Void, Error>) {
        let waiting = arrivals
        arrivals.removeAll()
        waiting.forEach { $0.resume(with: outcome) }
    }
}

/// A cursor store that logs saves into a shared order with the History store.
actor OrderedCursorStore: SyncChangeTokenStore {
    private var token: Data?
    private let store: FakeHistoryStore?
    private(set) var saves: [Data] = []

    init(token: Data?, loggingInto store: FakeHistoryStore? = nil) {
        self.token = token
        self.store = store
    }

    func loadChangeToken() async throws -> Data? { token }

    func saveChangeToken(_ token: Data) async throws {
        self.token = token
        saves.append(token)
        await store?.note("save-cursor")
    }

    func clearChangeToken() async throws {
        token = nil
    }
}

extension FakeHistoryStore {
    func note(_ event: String) {
        log.append(event)
    }
}
