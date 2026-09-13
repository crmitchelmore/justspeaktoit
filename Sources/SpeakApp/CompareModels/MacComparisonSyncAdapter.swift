import AppKit
import Combine
import CloudKit
import Foundation
import SpeakCore
import SpeakSync

@MainActor
final class MacComparisonSyncAdapter: ComparisonSyncDelegate {
    private let store: ComparisonRoundStore
    private let engine: ComparisonSyncEngine
    private var observers: Set<AnyCancellable> = []
    private var retryTask: Task<Void, Never>?

    init(store: ComparisonRoundStore, engine: ComparisonSyncEngine? = nil, defaults _: UserDefaults = .standard) {
        self.store = store
        self.engine = engine ?? .shared
        store.onRoundUpserted = { [weak self] _ in self?.requestSync() }
        store.onRoundRemoved = { [weak self] _ in self?.requestSync() }
    }

    deinit { retryTask?.cancel() }

    func start() async {
        await engine.initialize(delegate: self)
        if retryTask == nil {
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .merge(with: NotificationCenter.default.publisher(for: .CKAccountChanged))
                .sink { [weak self] _ in
                    Task { @MainActor in self?.requestSync() }
                }.store(in: &observers)
            // Also retries while the app remains open, including after reconnect.
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: .seconds(30))) != nil else { return }
                    await self?.sync()
                }
            }
        }
        await sync()
    }

    func sync() async {
        await engine.sync()
        store.syncError = engine.lastError?.localizedDescription
    }

    private func requestSync() { Task { [weak self] in await self?.sync() } }

    func pendingRevisions() -> [ModelComparisonRevision] { store.pendingRevisions }

    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws {
        try store.applyRevision(revision)
    }

    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws {
        try store.acknowledge(revisions)
    }

    func applyLegacyDeletion(id: UUID) async throws {
        guard !store.pendingRevisions.contains(where: { $0.id == id }), let round = store.round(id: id) else { return }
        try store.applyRevision(ModelComparisonRevision(deleting: id, at: round.updatedAt))
    }
}
