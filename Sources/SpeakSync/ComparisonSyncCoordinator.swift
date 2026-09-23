import Foundation
import SpeakCore

public enum ComparisonRemoteChange {
    case changed(ModelComparisonRound)
    case deleted(UUID)
    case revision(ModelComparisonRevision)
}

public struct ComparisonChangePage {
    public var changes: [ComparisonRemoteChange]
    public var serverChangeTokenData: Data?
    public var moreComing: Bool
    public static let empty = ComparisonChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)

    public init(changes: [ComparisonRemoteChange], serverChangeTokenData: Data?, moreComing: Bool) {
        self.changes = changes
        self.serverChangeTokenData = serverChangeTokenData
        self.moreComing = moreComing
    }
}

public struct ComparisonUploadResult {
    public var acknowledged: [ModelComparisonRevision] = []
    public var remote: [ModelComparisonRevision] = []
    public var failures: [UUID: Error] = [:]

    public init(
        acknowledged: [ModelComparisonRevision] = [],
        remote: [ModelComparisonRevision] = [],
        failures: [UUID: Error] = [:]
    ) {
        self.acknowledged = acknowledged
        self.remote = remote
        self.failures = failures
    }
}

/// One Compare Models change feed and record store. It shares the History zone
/// but walks it with its own cursor and ignores every other record type.
public protocol ComparisonSyncTransport: AnyObject {
    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage
    func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult
}

/// Where reconciled rounds land; asynchronous for the same reason as `HistorySyncStore`.
public protocol ComparisonSyncStore: AnyObject {
    func pendingRevisions() async -> [ModelComparisonRevision]
    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws
    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws
    func applyLegacyDeletion(id: UUID) async throws
}

public struct ComparisonSyncStatus {
    public enum Field: Sendable {
        case isSyncing
        case lastError
        case lastSyncTime
    }

    public var isSyncing = false
    public var lastError: Error?
    public var lastSyncTime: Date?

    public init() {}
}

public protocol ComparisonSyncStatusObserver: AnyObject {
    func comparisonSync(_ status: ComparisonSyncStatus, didChange field: ComparisonSyncStatus.Field) async
}

/// The upload conflict rule every comparison transport applies: a newer CloudKit
/// revision wins, and at equal times a deletion wins over a round.
enum ComparisonConflictPolicy {
    static func remoteWins(_ remote: ModelComparisonRevision, over local: ModelComparisonRevision) -> Bool {
        remote.updatedAt > local.updatedAt
            || (remote.updatedAt == local.updatedAt && remote.round == nil)
    }
}

/// One serialized reconciliation path handles local writes, retry and remote
/// changes. Confined to the caller's isolation like `HistorySyncCoordinator`.
public final class ComparisonSyncCoordinator {
    public static let maxCoalescedPasses = 3

    public private(set) var status = ComparisonSyncStatus()

    private let transport: any ComparisonSyncTransport
    private let tokenStore: any SyncChangeTokenStore
    private let cloudAvailability: () async -> Bool
    private let isChangeTokenExpired: @Sendable (Error) -> Bool
    private let observer: (any ComparisonSyncStatusObserver)?
    private let now: @Sendable () -> Date
    private var followUpRequested = false

    /// `isChangeTokenExpired` recognises a transport's "cursor expired" error;
    /// the pass then restarts that feed from the beginning exactly once.
    public init(
        transport: any ComparisonSyncTransport,
        tokenStore: any SyncChangeTokenStore,
        cloudAvailability: @escaping () async -> Bool,
        isChangeTokenExpired: @escaping @Sendable (Error) -> Bool = { _ in false },
        observer: (any ComparisonSyncStatusObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.cloudAvailability = cloudAvailability
        self.isChangeTokenExpired = isChangeTokenExpired
        self.observer = observer
        self.now = now
    }

    /// A `nil` store makes the call a no-op, as it has always been.
    public func sync(
        store: (any ComparisonSyncStore)?,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        guard let store else { return }
        guard !status.isSyncing else {
            followUpRequested = true
            return
        }
        await set(\.isSyncing, true, .isSyncing, isolation: isolation)
        var passes = 0
        repeat {
            followUpRequested = false
            do {
                guard await cloudAvailability() else { throw SyncError.cloudUnavailable }
                do {
                    try await fetchRemoteChanges(store: store, isolation: isolation)
                } catch let error where isChangeTokenExpired(error) {
                    try await tokenStore.clearChangeToken()
                    try await fetchRemoteChanges(store: store, isolation: isolation)
                }
                try await uploadPending(store: store, isolation: isolation)
                await set(\.lastError, nil, .lastError, isolation: isolation)
                await set(\.lastSyncTime, now(), .lastSyncTime, isolation: isolation)
            } catch {
                await set(\.lastError, error, .lastError, isolation: isolation)
            }
            passes += 1
        } while followUpRequested && passes < Self.maxCoalescedPasses
        await set(\.isSyncing, false, .isSyncing, isolation: isolation)
    }

    private func fetchRemoteChanges(
        store: any ComparisonSyncStore,
        isolation: isolated (any Actor)?
    ) async throws {
        var token = try await tokenStore.loadChangeToken()
        while true {
            let page = try await transport.fetchChanges(after: token)
            guard !page.moreComing || (page.serverChangeTokenData != nil && page.serverChangeTokenData != token) else {
                throw SyncError.invalidChangePage
            }
            for change in page.changes {
                switch change {
                case .changed(let round): try await store.applyRemoteRevision(ModelComparisonRevision(round: round))
                case .revision(let revision): try await store.applyRemoteRevision(revision)
                case .deleted(let id): try await store.applyLegacyDeletion(id: id)
                }
            }
            // Throwing persistence prevents cursor advancement. Replay is idempotent.
            if let next = page.serverChangeTokenData {
                try await tokenStore.saveChangeToken(next)
                token = next
            }
            if !page.moreComing { return }
        }
    }

    private func uploadPending(
        store: any ComparisonSyncStore,
        isolation: isolated (any Actor)?
    ) async throws {
        // Snapshot each batch. Acknowledgements carry precisely the submitted revision.
        var remaining = await store.pendingRevisions()
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(SyncSchema.batchSize))
            remaining.removeFirst(batch.count)
            let result = await transport.upload(revisions: batch)
            for remote in result.remote { try await store.applyRemoteRevision(remote) }
            try await store.acknowledgeRevisions(result.acknowledged)
            if !result.failures.isEmpty { throw SyncError.partialUploadFailure(result.failures.count) }
        }
    }

    private func set<Value>(
        _ keyPath: WritableKeyPath<ComparisonSyncStatus, Value>,
        _ value: Value,
        _ field: ComparisonSyncStatus.Field,
        isolation: isolated (any Actor)?
    ) async {
        status[keyPath: keyPath] = value
        await observer?.comparisonSync(status, didChange: field)
    }
}
