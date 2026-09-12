import Foundation
import SpeakCore
import SpeakSync

/// Bridges `ComparisonRoundStore` with CloudKit so judged rounds appear on
/// every Mac signed into the same iCloud account (issue #1101).
///
/// The shape follows `MacHistorySyncAdapter`: local mutations upload, remote
/// changes apply without echoing back, and the set of acknowledged ids is
/// kept in `UserDefaults` so relaunches do not re-upload everything.
@MainActor
final class MacComparisonSyncAdapter: ComparisonSyncDelegate {
    private let store: ComparisonRoundStore
    private let engine: ComparisonSyncEngine
    private let defaults: UserDefaults
    private var syncedIDs: Set<UUID> = []
    private var isApplyingRemoteChange = false
    private let log = SpeakLogger.logger(category: "MacComparisonSync")

    static let syncedIDsKey = "speak.sync.syncedComparisonRoundIDs"

    init(store: ComparisonRoundStore, engine: ComparisonSyncEngine? = nil, defaults: UserDefaults = .standard) {
        self.store = store
        self.engine = engine ?? .shared
        self.defaults = defaults
        if let strings = defaults.stringArray(forKey: Self.syncedIDsKey) {
            syncedIDs = Set(strings.compactMap(UUID.init(uuidString:)))
        }
        store.onRoundUpserted = { [weak self] round in
            self?.upload(round)
        }
        store.onRoundRemoved = { [weak self] id in
            self?.delete(id: id)
        }
    }

    func start() async {
        await engine.initialize(delegate: self)
        await engine.sync()
    }

    func sync() async {
        await engine.sync()
    }

    private func upload(_ round: ModelComparisonRound) {
        guard !isApplyingRemoteChange else { return }
        // A re-judged round must go up again.
        syncedIDs.remove(round.id)
        persistSyncedIDs()
        Task {
            do {
                try await engine.upload(round: round)
            } catch {
                log.error("Comparison upload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func delete(id: UUID) {
        guard !isApplyingRemoteChange else { return }
        syncedIDs.remove(id)
        persistSyncedIDs()
        Task {
            try? await engine.delete(roundID: id)
        }
    }

    // MARK: ComparisonSyncDelegate

    func pendingRounds() -> [ModelComparisonRound] {
        store.allRounds.filter { !syncedIDs.contains($0.id) }
    }

    func didReceiveRemoteRound(_ round: ModelComparisonRound) async {
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        if let local = store.round(id: round.id), local.updatedAt > round.updatedAt {
            // The local copy is newer; it must upload, so it stays pending.
            syncedIDs.remove(round.id)
        } else {
            store.applyRemote(round)
            syncedIDs.insert(round.id)
        }
        persistSyncedIDs()
    }

    func didDeleteRemoteRound(id: UUID) async {
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        store.removeRemote(id: id)
        syncedIDs.remove(id)
        persistSyncedIDs()
    }

    func didAcknowledgeSyncedRounds(ids: Set<UUID>) async {
        syncedIDs.formUnion(ids)
        persistSyncedIDs()
    }

    private func persistSyncedIDs() {
        defaults.set(syncedIDs.map(\.uuidString).sorted(), forKey: Self.syncedIDsKey)
    }
}
