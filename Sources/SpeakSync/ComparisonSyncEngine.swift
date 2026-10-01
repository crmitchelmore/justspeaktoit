import CloudKit
import Foundation
import SpeakCore

@MainActor
public protocol ComparisonSyncDelegate: AnyObject {
    func pendingRevisions() -> [ModelComparisonRevision]
    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws
    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws
    func applyLegacyDeletion(id: UUID) async throws
}

enum ComparisonRemoteChange {
    case changed(ModelComparisonRound)
    case deleted(UUID)
    case revision(ModelComparisonRevision)
}

struct ComparisonChangePage {
    var changes: [ComparisonRemoteChange]
    var serverChangeTokenData: Data?
    var moreComing: Bool
    static let empty = ComparisonChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)
}

struct ComparisonUploadResult {
    var acknowledged: [ModelComparisonRevision] = []
    var remote: [ModelComparisonRevision] = []
    var failures: [UUID: Error] = [:]
}

@MainActor
protocol ComparisonSyncTransport: AnyObject {
    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage
    func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult
}

/// One serialized reconciliation path handles local writes, retry and remote changes.
@MainActor
public final class ComparisonSyncEngine: ObservableObject {
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastError: Error?
    @Published public private(set) var lastSyncTime: Date?
    public static let shared = ComparisonSyncEngine()
    public static let syncTokenKey = "speak.sync.comparison.serverChangeToken"
    static let maxCoalescedPasses = 3

    private weak var delegate: ComparisonSyncDelegate?
    private let transport: ComparisonSyncTransport
    private let defaults: UserDefaults
    private let cloudAvailability: () async -> Bool
    private var followUpRequested = false

    private convenience init() {
        self.init(transport: CloudKitComparisonSyncTransport(), defaults: .standard, cloudAvailability: {
            guard SyncConfiguration.hasCloudKitEntitlement else { return false }
            return (try? await SyncConfiguration.container?.accountStatus()) == .available
        })
    }

    init(transport: ComparisonSyncTransport, defaults: UserDefaults, cloudAvailability: @escaping () async -> Bool) {
        self.transport = transport
        self.defaults = defaults
        self.cloudAvailability = cloudAvailability
    }

    public func initialize(delegate: ComparisonSyncDelegate) async { self.delegate = delegate }

    public func sync() async {
        guard delegate != nil else { return }
        guard !isSyncing else { followUpRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        var passes = 0
        repeat {
            followUpRequested = false
            do {
                guard await cloudAvailability() else { throw SyncError.cloudUnavailable }
                do {
                    try await fetchRemoteChanges()
                } catch let error as CKError where error.code == .changeTokenExpired {
                    defaults.removeObject(forKey: Self.syncTokenKey)
                    try await fetchRemoteChanges()
                }
                try await uploadPending()
                lastError = nil
                lastSyncTime = Date()
            } catch {
                lastError = error
            }
            passes += 1
        } while followUpRequested && passes < Self.maxCoalescedPasses
    }

    private func fetchRemoteChanges() async throws {
        guard let delegate else { throw SyncError.delegateUnavailable }
        var token = defaults.data(forKey: Self.syncTokenKey)
        while true {
            let page = try await transport.fetchChanges(after: token)
            guard !page.moreComing || (page.serverChangeTokenData != nil && page.serverChangeTokenData != token) else {
                throw SyncError.invalidChangePage
            }
            for change in page.changes {
                switch change {
                case .changed(let round): try await delegate.applyRemoteRevision(ModelComparisonRevision(round: round))
                case .revision(let revision): try await delegate.applyRemoteRevision(revision)
                case .deleted(let id): try await delegate.applyLegacyDeletion(id: id)
                }
            }
            // Throwing persistence prevents cursor advancement. Replay is idempotent.
            if let next = page.serverChangeTokenData {
                defaults.set(next, forKey: Self.syncTokenKey)
                token = next
            }
            if !page.moreComing { return }
        }
    }

    private func uploadPending() async throws {
        guard let delegate else { throw SyncError.delegateUnavailable }
        // Snapshot each batch. Acknowledgements carry precisely the submitted revision.
        var remaining = delegate.pendingRevisions()
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(SyncConfiguration.batchSize))
            remaining.removeFirst(batch.count)
            let result = await transport.upload(revisions: batch)
            for remote in result.remote { try await delegate.applyRemoteRevision(remote) }
            try await delegate.acknowledgeRevisions(result.acknowledged)
            if !result.failures.isEmpty { throw SyncError.partialUploadFailure(result.failures.count) }
        }
    }
}
