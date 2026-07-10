// swiftlint:disable file_length
#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync

// MARK: - History Manager

/// Manages transcription history persistence for iOS with CloudKit sync.
@MainActor
// swiftlint:disable:next type_body_length
public final class iOSHistoryManager: ObservableObject {
    public static let shared = iOSHistoryManager()

    @Published public private(set) var items: [iOSHistoryItem] = []
    @Published public private(set) var isLoading = false

    /// IDs currently being reprocessed (drives per-row progress in the UI).
    @Published public private(set) var reprocessingIDs: Set<UUID> = []

    private let fileURL: URL
    private let tombstoneStore: HistoryTombstoneStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Whether CloudKit sync is wired up. Disabled in unit tests so persistence
    /// can be exercised in isolation.
    private let syncEnabled: Bool

    /// Guards against loading twice and, crucially, against saving from an
    /// unloaded (empty) state — the root cause of background-recording history
    /// loss (see `loadHistoryFromDiskIfNeeded`).
    private var hasLoadedFromDisk = false

    /// IDs of entries that have been synced to CloudKit.
    private(set) var syncedIDs: Set<UUID> = []
    private let syncedIDsKey = "speak.sync.syncedHistoryIDs"
    private(set) var tombstones: [HistoryDeletionTombstone] = []

    /// Number of entries synced to CloudKit.
    public var syncedCount: Int { syncedIDs.count }

    /// Number of entries not yet synced.
    public var unsyncedCount: Int {
        items.filter { !syncedIDs.contains($0.id) }.count
    }

    /// Whether a specific item has been synced.
    public func isSynced(_ item: iOSHistoryItem) -> Bool {
        syncedIDs.contains(item.id)
    }

    private convenience init() {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            fileURL: documentsURL.appendingPathComponent("transcription-history.json"),
            syncEnabled: true
        )
    }

    /// Designated initializer. `fileURL` and `syncEnabled` are injectable so
    /// tests can exercise persistence against a temporary file without touching
    /// CloudKit.
    init(fileURL: URL, syncEnabled: Bool, tombstoneStore: HistoryTombstoneStore? = nil) {
        self.fileURL = fileURL
        self.syncEnabled = syncEnabled
        self.tombstoneStore = tombstoneStore ?? HistoryTombstoneStore(
            fileURL: fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("transcription-history-tombstones.json")
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSyncedIDs()
        tombstones = self.tombstoneStore.load()

        // Load history *synchronously* before this initializer returns. A
        // headless Action Button recording touches `.shared` cold and then
        // immediately calls `recordTranscription`; the previous async load left
        // a window where the save ran against an empty in-memory list and wiped
        // all prior history on disk.
        loadHistoryFromDiskIfNeeded()

        guard syncEnabled else { return }
        MacConnection.shared.historyTransportDelegate = self
        Task {
            await initializeSync()
        }
    }

    // MARK: - CloudKit Sync Init

    private func initializeSync() async {
        await HistorySyncEngine.shared.initialize(delegate: self)
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Public API

    /// Adds a new transcription to history.
    public func add(_ item: iOSHistoryItem) {
        loadHistoryFromDiskIfNeeded()
        items.insert(item, at: 0)
        saveHistory()

        guard syncEnabled else { return }
        let entry = item.toSyncable()
        Task {
            do {
                try await HistorySyncEngine.shared.upload(entry: entry)
                syncedIDs.insert(item.id)
                saveSyncedIDs()
            } catch {
                // Leave the item unsynced so a later full sync retries it,
                // rather than marking it synced after a failed upload.
                print("[iOSHistoryManager] Failed to upload item: \(error)")
            }
        }
        Task {
            await MacConnection.shared.broadcastHistoryDelta(entries: [entry], tombstones: [])
        }
    }

    /// Creates and adds a history item from transcription result.
    public func recordTranscription(
        text: String,
        model: String,
        duration: TimeInterval
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let item = iOSHistoryItem(
            transcription: text,
            model: model,
            duration: duration,
            wordCount: text.split(separator: " ").count
        )
        add(item)
    }

    /// Removes an item from history.
    public func remove(_ item: iOSHistoryItem) {
        loadHistoryFromDiskIfNeeded()
        items.removeAll { $0.id == item.id }
        let tombstone = HistoryDeletionTombstone(id: item.id, deletedAt: Date())
        recordTombstones([tombstone])
        saveHistory()

        guard syncEnabled else { return }
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
            syncedIDs.remove(item.id)
            saveSyncedIDs()
        }
        Task {
            await MacConnection.shared.broadcastHistoryDelta(entries: [], tombstones: [tombstone])
        }
    }

    /// Clears all history.
    public func clearAll() {
        loadHistoryFromDiskIfNeeded()
        let tombstonesToSend = items.map { HistoryDeletionTombstone(id: $0.id, deletedAt: Date()) }
        let allIDs = items.map(\.id)
        items.removeAll()
        recordTombstones(tombstonesToSend)
        saveHistory()

        guard syncEnabled else { return }
        Task {
            for entryID in allIDs {
                try? await HistorySyncEngine.shared.delete(entryID: entryID)
            }
            syncedIDs.removeAll()
            saveSyncedIDs()
        }
        Task {
            await MacConnection.shared.broadcastHistoryDelta(entries: [], tombstones: tombstonesToSend)
        }
    }

    /// Trigger a manual sync.
    public func triggerSync() async {
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Reprocess

    /// Re-runs post-processing on an entry with the current model/prompt and
    /// stores the polished result alongside the raw transcript (mirrors the Mac
    /// "Reprocess with current model" action). Surfaces failures on the entry.
    public func reprocess(_ item: iOSHistoryItem) async {
        let settings = AppSettings.shared
        guard settings.hasOpenRouterKey else {
            setError("Add an OpenRouter API key in Settings to reprocess.", for: item.id)
            return
        }
        guard !reprocessingIDs.contains(item.id) else { return }

        reprocessingIDs.insert(item.id)
        defer { reprocessingIDs.remove(item.id) }

        do {
            let polished = try await iOSPostProcessingManager.shared.polish(
                text: item.transcription,
                model: settings.postProcessingModel,
                prompt: settings.postProcessingPrompt,
                apiKey: settings.openRouterAPIKey
            )
            setPostProcessed(polished, for: item.id)
        } catch is CancellationError {
            // Reprocess was cancelled (e.g. the user navigated away) — leave the
            // entry untouched rather than persisting a confusing error.
        } catch {
            setError(error.localizedDescription, for: item.id)
        }
    }

    /// Stores a polished transcript on an entry and re-syncs it.
    public func setPostProcessed(_ processed: String, for id: UUID) {
        loadHistoryFromDiskIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].withPostProcessed(processed)
        saveHistory()

        guard syncEnabled else { return }
        let entry = items[index].toSyncable()
        // Mark the entry unsynced until the updated version uploads, so a failed
        // upload is retried by the next full sync instead of silently desyncing.
        syncedIDs.remove(id)
        saveSyncedIDs()
        Task {
            do {
                try await HistorySyncEngine.shared.upload(entry: entry)
                syncedIDs.insert(id)
                saveSyncedIDs()
            } catch {
                print("[iOSHistoryManager] Failed to upload reprocessed item: \(error)")
            }
        }
        Task {
            await MacConnection.shared.broadcastHistoryDelta(entries: [entry], tombstones: [])
        }
    }

    /// Records an error against an entry (surfaced in the history UI).
    public func setError(_ message: String, for id: UUID) {
        loadHistoryFromDiskIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].withError(message)
        saveHistory()
    }

    /// Whether an entry is currently being reprocessed.
    public func isReprocessing(_ item: iOSHistoryItem) -> Bool {
        reprocessingIDs.contains(item.id)
    }

    // MARK: - Persistence

    /// Loads history from disk exactly once, synchronously. Every mutation
    /// funnels through this first so we never write from an unloaded (empty)
    /// list and clobber the file. Called eagerly from `init` and defensively
    /// from `add`/`remove`/`clearAll`.
    private func loadHistoryFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Nothing to load — safe to start from an empty list.
            hasLoadedFromDisk = true
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try decoder.decode([iOSHistoryItem].self, from: data)
            // Only mark loaded once we've actually read the file. A transient
            // failure (e.g. file protection while the device is locked during a
            // background recording) must be retried, never treated as "loaded"
            // and then clobbered by the next save.
            hasLoadedFromDisk = true
        } catch {
            print("[iOSHistoryManager] Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let data = try encoder.encode(items)
            // `completeUntilFirstUserAuthentication` keeps the file readable and
            // writable from a background (Action Button) recording after the
            // first unlock, so headless sessions can persist without data loss.
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            print("[iOSHistoryManager] Failed to save history: \(error)")
        }
    }

    private func recordTombstones(_ newTombstones: [HistoryDeletionTombstone]) {
        guard !newTombstones.isEmpty else { return }
        let merged = HistoryConflictResolver.mergedTombstones(
            existing: tombstones,
            incoming: newTombstones
        )
        tombstones = tombstoneStore.pruned(Array(merged.values))
        do {
            try tombstoneStore.save(tombstones)
        } catch {
            print("[iOSHistoryManager] Failed to save history tombstones: \(error)")
        }
    }

    // swiftlint:disable:next function_body_length
    private func applyRemote(
        entries incomingEntries: [SyncableHistoryEntry],
        tombstones incomingTombstones: [HistoryDeletionTombstone],
        markCloudSynced: Bool
    ) -> HistorySyncSnapshot {
        loadHistoryFromDiskIfNeeded()
        let mergedTombstones = HistoryConflictResolver.mergedTombstones(
            existing: tombstones,
            incoming: incomingTombstones
        )
        tombstones = tombstoneStore.pruned(Array(mergedTombstones.values))
        do {
            try tombstoneStore.save(tombstones)
        } catch {
            print("[iOSHistoryManager] Failed to save merged history tombstones: \(error)")
        }

        let existingSyncEntries = items.map { $0.toSyncable() }
        let mergedSyncEntries = HistoryConflictResolver.mergedEntries(
            existing: existingSyncEntries,
            incoming: incomingEntries,
            tombstones: tombstones
        )
        let existingByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = mergedSyncEntries.map { entry in
            if let existing = existingByID[entry.id], existing.toSyncable() == entry {
                return existing
            }
            return iOSHistoryItem.fromSyncable(entry)
        }
        items.sort { $0.createdAt > $1.createdAt }
        saveHistory()

        let finalEntriesByID = Dictionary(
            uniqueKeysWithValues: mergedSyncEntries.map { ($0.id, $0) }
        )
        let incomingWinners = HistoryConflictResolver.mergedEntries(
            existing: [],
            incoming: incomingEntries,
            tombstones: []
        )
        let appliedEntries = incomingWinners.filter { finalEntriesByID[$0.id] == $0 }
        let incomingTombstonesByID = HistoryConflictResolver.mergedTombstones(
            existing: [],
            incoming: incomingTombstones
        )
        let appliedTombstones = incomingTombstonesByID.values.filter { tombstone in
            finalEntriesByID[tombstone.id] == nil
                && mergedTombstones[tombstone.id] == tombstone
        }

        if markCloudSynced {
            let appliedIDs = Set(appliedEntries.map(\.id))
            syncedIDs.formUnion(appliedIDs)
            syncedIDs.subtract(incomingEntries.map(\.id).filter { !appliedIDs.contains($0) })
        }
        syncedIDs.subtract(incomingTombstones.map(\.id))
        saveSyncedIDs()

        return HistorySyncSnapshot(
            entries: appliedEntries,
            tombstones: Array(appliedTombstones)
        )
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

// MARK: - HistorySyncDelegate

extension iOSHistoryManager: HistorySyncDelegate {
    public func pendingEntries() -> [SyncableHistoryEntry] {
        HistoryConflictResolver.visibleEntries(
            entries: items.map { $0.toSyncable() },
            tombstones: tombstones
        )
            .filter { !syncedIDs.contains($0.id) }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) {
        _ = applyRemote(entries: [entry], tombstones: [], markCloudSynced: true)
    }

    public func didDeleteRemoteEntry(id: UUID) {
        _ = applyRemote(
            entries: [],
            tombstones: [HistoryDeletionTombstone(id: id, deletedAt: Date(), originDeviceID: "cloudkit")],
            markCloudSynced: true
        )
    }

    public func didUploadPendingEntries(ids: [UUID]) {
        syncedIDs.formUnion(ids)
        saveSyncedIDs()
    }
}

extension iOSHistoryManager: HistoryTransportDelegate {
    public func historySnapshot(maxEntries: Int) -> HistorySyncSnapshot {
        loadHistoryFromDiskIfNeeded()
        let visibleEntries = HistoryConflictResolver.visibleEntries(
            entries: items.map { $0.toSyncable() },
            tombstones: tombstones
        )
        return HistorySyncSnapshot(
            entries: Array(visibleEntries.prefix(maxEntries)),
            tombstones: Array(tombstones.prefix(maxEntries))
        )
    }

    public func applyHistoryBatch(
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) async {
        let applied = applyRemote(
            entries: entries,
            tombstones: tombstones,
            markCloudSynced: false
        )
        syncedIDs.subtract(applied.entries.map(\.id))
        syncedIDs.subtract(applied.tombstones.map(\.id))
        saveSyncedIDs()
        guard syncEnabled, HistorySyncEngine.shared.state.isCloudAvailable else { return }

        for entry in applied.entries {
            do {
                try await HistorySyncEngine.shared.upload(entry: entry)
                syncedIDs.insert(entry.id)
            } catch {
                syncedIDs.remove(entry.id)
                print("[iOSHistoryManager] Failed to bridge transport entry to CloudKit: \(error)")
            }
        }
        for tombstone in applied.tombstones {
            do {
                try await HistorySyncEngine.shared.delete(entryID: tombstone.id)
                syncedIDs.remove(tombstone.id)
            } catch {
                print("[iOSHistoryManager] Failed to bridge transport deletion to CloudKit: \(error)")
            }
        }
        saveSyncedIDs()
    }
}
#endif
