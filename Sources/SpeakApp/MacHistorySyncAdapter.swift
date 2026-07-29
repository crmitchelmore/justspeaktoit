import Foundation
import SpeakSync
import os.log

/// Bridges the macOS HistoryManager with CloudKit sync.
@MainActor
final class MacHistorySyncAdapter: HistorySyncDelegate {

    private let historyManager: HistoryManager
    private var syncedIDs: Set<UUID> = []
    private let syncedIDsKey = "speak.sync.syncedMacHistoryIDs"
    private let log = Logger(
        subsystem: "com.justspeaktoit",
        category: "MacHistorySync"
    )

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
        loadSyncedIDs()
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
            } catch {
                log.error("History upload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Delete an item from CloudKit when removed locally.
    func deleteItem(id: UUID) {
        syncedIDs.remove(id)
        saveSyncedIDs()
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: id)
        }
    }

    // MARK: - HistorySyncDelegate

    func pendingEntries() -> [SyncableHistoryEntry] {
        historyManager.allItems
            .filter { !syncedIDs.contains($0.id) }
            .prefix(SyncConfiguration.batchSize)
            .map { $0.toSyncable() }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        if let local = historyManager.allItems.first(where: { $0.id == entry.id }) {
            if entry.updatedAt > local.updatedAt {
                await historyManager.update(HistoryItem.fromSyncable(entry))
                syncedIDs.insert(entry.id)
            } else if entry.updatedAt == local.updatedAt {
                syncedIDs.insert(entry.id)
            } else {
                syncedIDs.remove(entry.id)
            }
            saveSyncedIDs()
            return
        }

        let item = HistoryItem.fromSyncable(entry)
        await historyManager.append(item)
        syncedIDs.insert(entry.id)
        saveSyncedIDs()
    }

    func didDeleteRemoteEntry(id: UUID) async {
        await historyManager.remove(id: id)
        syncedIDs.remove(id)
        saveSyncedIDs()
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        syncedIDs.formUnion(ids)
        saveSyncedIDs()
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
            updatedAt: updatedAt
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
            errors: []
        )
    }
}
