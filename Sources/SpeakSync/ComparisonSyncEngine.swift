import CloudKit
import Foundation
import SpeakCore
import os.log

/// Platform hooks the comparison sync engine reconciles through.
@MainActor
public protocol ComparisonSyncDelegate: AnyObject {
    /// Local rounds CloudKit has not acknowledged yet.
    func pendingRounds() -> [ModelComparisonRound]
    /// A new or updated round from CloudKit. Last writer wins on `updatedAt`.
    func didReceiveRemoteRound(_ round: ModelComparisonRound) async
    func didDeleteRemoteRound(id: UUID) async
    func didAcknowledgeSyncedRounds(ids: Set<UUID>) async
}

enum ComparisonRemoteChange {
    case changed(ModelComparisonRound)
    case deleted(UUID)

    var id: UUID {
        switch self {
        case .changed(let round): return round.id
        case .deleted(let id): return id
        }
    }
}

struct ComparisonChangePage {
    var changes: [ComparisonRemoteChange]
    var serverChangeTokenData: Data?
    var moreComing: Bool

    static let empty = ComparisonChangePage(changes: [], serverChangeTokenData: nil, moreComing: false)
}

struct ComparisonUploadResult {
    var acknowledgedIDs: Set<UUID>
    /// Rounds CloudKit already held in a newer state than what was uploaded.
    var remoteRounds: [ModelComparisonRound]
    var failures: [UUID: Error]
}

@MainActor
protocol ComparisonSyncTransport: AnyObject {
    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage
    func upload(rounds: [ModelComparisonRound]) async -> ComparisonUploadResult
    func delete(roundID: UUID) async throws
}

/// Syncs Compare Models rounds through the History zone (issue #1101).
///
/// A deliberately small sibling of `HistorySyncEngine`: it walks the same
/// zone with its own change token, keeps only `ModelComparisonRound` records,
/// and hands them to a platform delegate. Zone and subscription creation are
/// left to the History engine, which always runs first on both platforms.
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
    private var isCloudAvailable = false
    private var followUpRequested = false
    private let log = SpeakLogger.logger(category: "ComparisonSync")

    private convenience init() {
        self.init(
            transport: CloudKitComparisonSyncTransport(),
            defaults: .standard,
            cloudAvailability: {
                guard SyncConfiguration.hasCloudKitEntitlement else { return false }
                let status = try? await SyncConfiguration.container?.accountStatus()
                return status == .available
            }
        )
    }

    init(
        transport: ComparisonSyncTransport,
        defaults: UserDefaults,
        cloudAvailability: @escaping () async -> Bool
    ) {
        self.transport = transport
        self.defaults = defaults
        self.cloudAvailability = cloudAvailability
    }

    public func initialize(delegate: ComparisonSyncDelegate) async {
        self.delegate = delegate
        isCloudAvailable = await cloudAvailability()
        if !isCloudAvailable {
            log.info("iCloud unavailable; comparison rounds stay local")
        }
    }

    /// Fetches remote rounds, reconciles them, then uploads pending rounds.
    /// A trigger during a running pass queues one follow-up pass.
    public func sync() async {
        guard isCloudAvailable, delegate != nil else { return }
        guard !isSyncing else {
            followUpRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        var passes = 0
        repeat {
            followUpRequested = false
            await runPass()
            passes += 1
        } while followUpRequested && passes < Self.maxCoalescedPasses
    }

    public func upload(round: ModelComparisonRound) async throws {
        guard isCloudAvailable else { throw SyncError.cloudUnavailable }
        guard delegate != nil else { throw SyncError.delegateUnavailable }
        let result = await transport.upload(rounds: [round])
        await apply(result)
        if let error = result.failures[round.id] {
            lastError = SyncError.cloudKit(error)
            throw lastError!
        }
        lastError = nil
    }

    public func delete(roundID: UUID) async throws {
        guard isCloudAvailable else { throw SyncError.cloudUnavailable }
        do {
            try await transport.delete(roundID: roundID)
        } catch {
            throw SyncError.cloudKit(error)
        }
    }

    private func runPass() async {
        do {
            try await fetchRemoteChanges()
            try await uploadPending()
            lastSyncTime = Date()
            lastError = nil
        } catch {
            lastError = error
            log.error("Comparison sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchRemoteChanges() async throws {
        var tokenData = defaults.data(forKey: Self.syncTokenKey)
        var finalTokenData = tokenData
        var changes: [ComparisonRemoteChange] = []
        while true {
            let page = try await transport.fetchChanges(after: tokenData)
            changes.append(contentsOf: page.changes)
            if let pageToken = page.serverChangeTokenData {
                guard !page.moreComing || pageToken != tokenData else { throw SyncError.invalidChangePage }
                tokenData = pageToken
                finalTokenData = pageToken
            } else if page.moreComing {
                throw SyncError.invalidChangePage
            }
            if !page.moreComing { break }
        }
        for change in Self.coalesced(changes) {
            switch change {
            case .changed(let round): await delegate?.didReceiveRemoteRound(round)
            case .deleted(let id): await delegate?.didDeleteRemoteRound(id: id)
            }
        }
        if let finalTokenData {
            defaults.set(finalTokenData, forKey: Self.syncTokenKey)
        }
    }

    /// Keeps the final event per round, in the order those final events came.
    static func coalesced(_ changes: [ComparisonRemoteChange]) -> [ComparisonRemoteChange] {
        var latest: [UUID: (offset: Int, change: ComparisonRemoteChange)] = [:]
        for (offset, change) in changes.enumerated() {
            latest[change.id] = (offset, change)
        }
        return latest.values.sorted { $0.offset < $1.offset }.map(\.change)
    }

    private func uploadPending() async throws {
        guard let delegate else { return }
        var previousCount = Int.max
        while true {
            let pending = delegate.pendingRounds()
            guard !pending.isEmpty else { return }
            // No progress since the last batch means CloudKit keeps rejecting
            // the same rounds; stop rather than loop forever.
            guard pending.count < previousCount else { throw SyncError.reconciliationIncomplete(pending.count) }
            previousCount = pending.count
            let result = await transport.upload(rounds: Array(pending.prefix(SyncConfiguration.batchSize)))
            await apply(result)
            if !result.failures.isEmpty { throw SyncError.partialUploadFailure(result.failures.count) }
        }
    }

    private func apply(_ result: ComparisonUploadResult) async {
        for round in result.remoteRounds {
            await delegate?.didReceiveRemoteRound(round)
        }
        if !result.acknowledgedIDs.isEmpty {
            await delegate?.didAcknowledgeSyncedRounds(ids: result.acknowledgedIDs)
        }
    }
}
