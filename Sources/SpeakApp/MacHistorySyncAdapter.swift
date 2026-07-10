import Foundation
import SpeakCore
import SpeakSync
import os.log

/// Bridges the macOS HistoryManager with CloudKit sync.
@MainActor
final class MacHistorySyncAdapter: HistorySyncDelegate {

    private let historyManager: HistoryManager
    private var syncedIDs: Set<UUID> = []
    private let syncedIDsKey = "speak.sync.syncedMacHistoryIDs"
    private weak var transportServer: TransportServer?
    private let log = Logger(
        subsystem: "com.justspeaktoit",
        category: "MacHistorySync"
    )

    init(historyManager: HistoryManager, transportServer: TransportServer? = nil) {
        self.historyManager = historyManager
        self.transportServer = transportServer
        loadSyncedIDs()
        self.transportServer?.historyTransportDelegate = self
        self.historyManager.onMutation = { [weak self] mutation in
            Task { @MainActor in
                await self?.handleLocalMutation(mutation)
            }
        }
    }

    /// Start sync — call after creating the adapter.
    func start() async {
        await HistorySyncEngine.shared.initialize(delegate: self)
        await HistorySyncEngine.shared.sync()
    }

    /// Upload a newly created history item.
    func uploadNewItem(_ item: HistoryItem) {
        Task {
            let entry = item.toSyncable()
            do {
                try await HistorySyncEngine.shared.upload(entry: entry)
                syncedIDs.insert(item.id)
                saveSyncedIDs()
            } catch {
                log.warning("CloudKit upload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Delete an item from CloudKit when removed locally.
    func deleteItem(id: UUID) {
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: id)
            syncedIDs.remove(id)
            saveSyncedIDs()
        }
    }

    // MARK: - HistorySyncDelegate

    func pendingEntries() -> [SyncableHistoryEntry] {
        historyManager.visibleSyncEntries()
            .filter { !syncedIDs.contains($0.id) }
            .prefix(SyncConfiguration.batchSize)
            .map { $0 }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) {
        Task {
            let applied = await historyManager.applyRemote(entries: [entry], tombstones: [])
            if applied.entries.contains(entry) {
                syncedIDs.insert(entry.id)
            } else {
                syncedIDs.remove(entry.id)
            }
            saveSyncedIDs()
        }
    }

    func didDeleteRemoteEntry(id: UUID) {
        Task {
            _ = await historyManager.applyRemote(
                entries: [],
                tombstones: [HistoryDeletionTombstone(id: id, deletedAt: Date(), originDeviceID: "cloudkit")]
            )
            syncedIDs.remove(id)
            saveSyncedIDs()
        }
    }

    func didUploadPendingEntries(ids: [UUID]) {
        syncedIDs.formUnion(ids)
        saveSyncedIDs()
    }

    private func handleLocalMutation(_ mutation: HistoryMutation) async {
        switch mutation.kind {
        case .upsert(let items):
            let entries = items.map { $0.toSyncable() }
            for entry in entries {
                do {
                    try await HistorySyncEngine.shared.upload(entry: entry)
                    syncedIDs.insert(entry.id)
                } catch {
                    syncedIDs.remove(entry.id)
                    log.warning("CloudKit upload failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            saveSyncedIDs()
            await transportServer?.broadcastHistoryDelta(entries: entries, tombstones: [])
        case .delete(let tombstones):
            for tombstone in tombstones {
                do {
                    try await HistorySyncEngine.shared.delete(entryID: tombstone.id)
                    syncedIDs.remove(tombstone.id)
                } catch {
                    log.warning("CloudKit delete failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            saveSyncedIDs()
            await transportServer?.broadcastHistoryDelta(entries: [], tombstones: tombstones)
        }
    }

    // MARK: - Synced IDs Tracking

    private func loadSyncedIDs() {
        if let strings = UserDefaults.standard.stringArray(
            forKey: syncedIDsKey
        ) {
            syncedIDs = Set(strings.compactMap { UUID(uuidString: $0) })
        }
    }

    private func saveSyncedIDs() {
        let strings = syncedIDs.map(\.uuidString)
        UserDefaults.standard.set(strings, forKey: syncedIDsKey)
    }
}

extension MacHistorySyncAdapter: HistoryTransportDelegate {
    func historySnapshot(maxEntries: Int) -> HistorySyncSnapshot {
        historyManager.historySnapshot(maxEntries: maxEntries)
    }

    func applyHistoryBatch(
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) async {
        let applied = await historyManager.applyRemote(
            entries: entries,
            tombstones: tombstones
        )
        syncedIDs.subtract(applied.entries.map(\.id))
        syncedIDs.subtract(applied.tombstones.map(\.id))
        saveSyncedIDs()
        guard HistorySyncEngine.shared.state.isCloudAvailable else { return }

        for entry in applied.entries {
            do {
                try await HistorySyncEngine.shared.upload(entry: entry)
                syncedIDs.insert(entry.id)
            } catch {
                syncedIDs.remove(entry.id)
                let message = error.localizedDescription
                log.warning(
                    "Failed to bridge transport entry to CloudKit: \(message, privacy: .public)"
                )
            }
        }
        for tombstone in applied.tombstones {
            do {
                try await HistorySyncEngine.shared.delete(entryID: tombstone.id)
                syncedIDs.remove(tombstone.id)
            } catch {
                let message = error.localizedDescription
                log.warning(
                    "Failed to bridge transport deletion to CloudKit: \(message, privacy: .public)"
                )
            }
        }
        saveSyncedIDs()
    }
}

// MARK: - HistoryItem Sync Conversion

extension HistoryItem {
    /// Convert macOS HistoryItem to syncable entry.
    func toSyncable() -> SyncableHistoryEntry {
        let primaryModel = modelUsages.first?.modelIdentifier
            ?? modelsUsed.first
            ?? "unknown"
        let text = postProcessedTranscription ?? rawTranscription
        let words = text?.split(separator: " ").count ?? 0

        return SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: rawTranscription,
            postProcessedText: postProcessedTranscription,
            model: primaryModel,
            duration: recordingDuration,
            wordCount: words,
            originPlatform: "macos",
            updatedAt: updatedAt,
            originDeviceID: originDeviceID ?? DeviceIdentity.deviceId
        )
    }

    /// Create a macOS HistoryItem from a synced remote entry.
    static func fromSyncable(_ entry: SyncableHistoryEntry) -> HistoryItem {
        HistoryItem(
            id: entry.id,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            modelsUsed: [entry.model],
            modelUsages: [],
            rawTranscription: entry.rawTranscription,
            postProcessedTranscription: entry.postProcessedText,
            recordingDuration: entry.duration,
            cost: nil,
            audioFileURL: nil,
            networkExchanges: [],
            events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: nil,
                recordingEnded: nil,
                transcriptionStarted: nil,
                transcriptionEnded: nil,
                postProcessingStarted: nil,
                postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .uiButton,
                hotKeyDescription: "Synced from \(entry.originPlatform)",
                outputMethod: .none,
                destinationApplication: nil
            ),
            personalCorrections: nil,
            errors: [],
            originDeviceID: entry.originDeviceID
        )
    }
}
