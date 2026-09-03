import Foundation
import SpeakCore
import SpeakSync
import os.log

/// Bridges the macOS HistoryManager with CloudKit sync.
@MainActor
final class MacHistorySyncAdapter: HistorySyncDelegate {

    private let historyManager: HistoryManager
    private let defaults: UserDefaults
    private var syncedIDs: Set<UUID> = []
    private let syncedIDsKey = "speak.sync.syncedMacHistoryIDs"
    private let log = SpeakLogger.logger(category: "MacHistorySync")

    /// True while a remote change is being applied to the local store, so the
    /// resulting HistoryManager mutation is not echoed back to CloudKit.
    private var isApplyingRemoteChange = false

    /// How long a synced-ID change waits for more changes before the set is
    /// written to `UserDefaults`. The sync engine hands remote entries to the
    /// delegate one at a time with no end-of-pass callback, so a whole
    /// download pass is folded into a single write by restarting this window
    /// on each change instead.
    private let saveInterval: Duration
    private var pendingSave: Task<Void, Never>?
    private var hasUnsavedSyncedIDs = false

    init(
        historyManager: HistoryManager,
        defaults: UserDefaults = .standard,
        saveInterval: Duration = .milliseconds(250)
    ) {
        self.historyManager = historyManager
        self.defaults = defaults
        self.saveInterval = saveInterval
        loadSyncedIDs()
        historyManager.onItemAppended = { [weak self] item in
            self?.uploadNewItem(item)
        }
        historyManager.onItemRemoved = { [weak self] id in
            self?.deleteItem(id: id)
        }
    }

    /// Start sync — call after creating the adapter.
    func start() async {
        await HistorySyncEngine.shared.initialize(delegate: self)
        await HistorySyncEngine.shared.sync()
    }

    /// Upload a newly created history item.
    func uploadNewItem(_ item: HistoryItem) {
        guard !isApplyingRemoteChange else { return }
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
        guard !isApplyingRemoteChange else { return }
        syncedIDs.remove(id)
        scheduleSaveSyncedIDs()
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
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        if let local = historyManager.item(id: entry.id) {
            if entry.updatedAt > local.updatedAt {
                await historyManager.update(HistoryItem.fromSyncable(entry))
                syncedIDs.insert(entry.id)
            } else if entry.updatedAt == local.updatedAt {
                syncedIDs.insert(entry.id)
            } else {
                // The local copy is newer, so it must be uploaded. Dropping the
                // ID is what puts it back into `pendingEntries()`, and a quit
                // inside the coalescing window would leave the stale ID on disk
                // and strand the local edit — so this one write is not
                // deferred (issue #851).
                syncedIDs.remove(entry.id)
                persistSyncedIDsNow()
                return
            }
            scheduleSaveSyncedIDs()
            return
        }

        let item = HistoryItem.fromSyncable(entry)
        await historyManager.append(item)
        syncedIDs.insert(entry.id)
        scheduleSaveSyncedIDs()
    }

    func didDeleteRemoteEntry(id: UUID) async {
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        await historyManager.remove(id: id)
        syncedIDs.remove(id)
        scheduleSaveSyncedIDs()
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        syncedIDs.formUnion(ids)
        scheduleSaveSyncedIDs()
    }

    // MARK: - Synced IDs Tracking

    private func loadSyncedIDs() {
        if let strings = defaults.stringArray(forKey: syncedIDsKey) {
            syncedIDs = Set(strings.compactMap { UUID(uuidString: $0) })
        }
    }

    /// Marks the synced-ID set dirty and (re)arms the coalescing window.
    ///
    /// A download pass reconciles up to a full CloudKit change set one entry
    /// at a time; writing the whole UUID array to `UserDefaults` per entry was
    /// O(entries × known IDs) of main-actor work for bookkeeping that is only
    /// read at launch. `pendingEntries()` and the rest of the adapter read
    /// `syncedIDs` from memory, so deferring the write changes nothing within
    /// a session; the only exposure is a quit inside the window, which at
    /// worst re-uploads already-synced entries (CloudKit saves are keyed by
    /// record ID, so that is idempotent). Termination flushes the window
    /// anyway, and the one removal that is not merely wasteful to lose —
    /// a remote record that lost to a newer local item — writes through
    /// immediately via `persistSyncedIDsNow()`.
    private func scheduleSaveSyncedIDs() {
        hasUnsavedSyncedIDs = true
        pendingSave?.cancel()
        let interval = saveInterval
        pendingSave = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return  // Superseded by a later change, which owns the write.
            }
            self?.flushSyncedIDs()
        }
    }

    /// Writes any coalesced synced-ID change immediately instead of waiting
    /// for the window to elapse. Safe to call at any time; a no-op when there
    /// is nothing pending.
    ///
    /// Synchronous on purpose: termination does not wait for async work, so
    /// `AppEnvironment.prepareForTermination()` calls this directly.
    func flushPendingSyncedIDs() {
        pendingSave?.cancel()
        flushSyncedIDs()
    }

    /// True while a coalesced synced-ID change is still only in memory.
    var hasPendingSyncedIDWrites: Bool { hasUnsavedSyncedIDs }

    /// Writes the synced-ID set through to `UserDefaults` right now, folding in
    /// anything the current coalescing window was still holding.
    private func persistSyncedIDsNow() {
        hasUnsavedSyncedIDs = true
        pendingSave?.cancel()
        flushSyncedIDs()
    }

    /// Writes the coalesced synced-ID set, if anything is still unsaved.
    private func flushSyncedIDs() {
        pendingSave = nil
        guard hasUnsavedSyncedIDs else { return }
        hasUnsavedSyncedIDs = false
        let strings = syncedIDs.map(\.uuidString)
        defaults.set(strings, forKey: syncedIDsKey)
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
