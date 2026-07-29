#if os(iOS)
import Foundation
import SpeakSync

// MARK: - History Manager

/// Manages transcription history persistence for iOS with CloudKit sync.
@MainActor
public final class iOSHistoryManager: ObservableObject {
    public static let shared = iOSHistoryManager()

    @Published public private(set) var items: [iOSHistoryItem] = []
    @Published public private(set) var isLoading = false

    /// IDs currently being reprocessed (drives per-row progress in the UI).
    @Published public private(set) var reprocessingIDs: Set<UUID> = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let userDefaults: UserDefaults

    /// Whether CloudKit sync is wired up. Disabled in unit tests so persistence
    /// can be exercised in isolation.
    private let syncEnabled: Bool

    /// Guards against loading twice and, crucially, against saving from an
    /// unloaded (empty) state — the root cause of background-recording history
    /// loss (see `loadHistoryFromDiskIfNeeded`).
    private var hasLoadedFromDisk = false

    /// IDs of entries that have been synced to CloudKit.
    @Published private(set) var syncedIDs: Set<UUID> = []
    static let syncedIDsKey = "speak.sync.syncedHistoryIDs"

    private var currentItemIDs: Set<UUID> {
        Set(items.map(\.id))
    }

    private var reconciledSyncedIDs: Set<UUID> {
        syncedIDs.intersection(currentItemIDs)
    }

    /// Number of entries synced to CloudKit.
    public var syncedCount: Int { reconciledSyncedIDs.count }

    /// Number of entries not yet synced.
    public var unsyncedCount: Int {
        items.count - syncedCount
    }

    /// Whether a specific item has been synced.
    public func isSynced(_ item: iOSHistoryItem) -> Bool {
        currentItemIDs.contains(item.id) && syncedIDs.contains(item.id)
    }

    private convenience init() {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            fileURL: documentsURL.appendingPathComponent("transcription-history.json"),
            syncEnabled: true,
            userDefaults: .standard
        )
    }

    /// Designated initializer. `fileURL` and `syncEnabled` are injectable so
    /// tests can exercise persistence against a temporary file without touching
    /// CloudKit.
    init(fileURL: URL, syncEnabled: Bool, userDefaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.syncEnabled = syncEnabled
        self.userDefaults = userDefaults

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSyncedIDs()

        // Load history *synchronously* before this initializer returns. A
        // headless Action Button recording touches `.shared` cold and then
        // immediately calls `recordTranscription`; the previous async load left
        // a window where the save ran against an empty in-memory list and wiped
        // all prior history on disk.
        loadHistoryFromDiskIfNeeded()

        guard syncEnabled else { return }
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
        Task {
            do {
                try await HistorySyncEngine.shared.upload(entry: item.toSyncable())
                syncedIDs.insert(item.id)
                saveSyncedIDs()
            } catch {
                // Leave the item unsynced so a later full sync retries it,
                // rather than marking it synced after a failed upload.
                print("[iOSHistoryManager] Failed to upload item: \(error)")
            }
        }
    }

    /// Creates and adds a history item from transcription result.
    @discardableResult
    public func recordTranscription(
        text: String,
        model: String,
        duration: TimeInterval
    ) -> iOSHistoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let item = iOSHistoryItem(
            transcription: text,
            model: model,
            duration: duration,
            wordCount: text.split(separator: " ").count
        )
        add(item)
        return item
    }

    /// Removes an item from history.
    public func remove(_ item: iOSHistoryItem) {
        loadHistoryFromDiskIfNeeded()
        items.removeAll { $0.id == item.id }
        saveHistory()
        syncedIDs.remove(item.id)
        saveSyncedIDs()

        guard syncEnabled else { return }
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
        }
    }

    /// Clears all history.
    public func clearAll() {
        loadHistoryFromDiskIfNeeded()
        let allIDs = items.map(\.id)
        items.removeAll()
        saveHistory()
        syncedIDs.removeAll()
        saveSyncedIDs()

        guard syncEnabled else { return }
        Task {
            for entryID in allIDs {
                try? await HistorySyncEngine.shared.delete(entryID: entryID)
            }
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
        reprocessingIDs.remove(id)
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
    }

    public func beginPostProcessing(for id: UUID) {
        reprocessingIDs.insert(id)
    }

    public func endPostProcessing(for id: UUID) {
        reprocessingIDs.remove(id)
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
            pruneStaleSyncedIDs()
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
            pruneStaleSyncedIDs()
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

    // MARK: - Synced IDs Tracking

    private func loadSyncedIDs() {
        if let strings = userDefaults.stringArray(
            forKey: Self.syncedIDsKey
        ) {
            syncedIDs = Set(strings.compactMap { UUID(uuidString: $0) })
        }
    }

    private func saveSyncedIDs() {
        let strings = syncedIDs.map(\.uuidString)
        userDefaults.set(strings, forKey: Self.syncedIDsKey)
    }

    private func pruneStaleSyncedIDs() {
        guard hasLoadedFromDisk else { return }
        let reconciled = reconciledSyncedIDs
        guard reconciled != syncedIDs else { return }
        syncedIDs = reconciled
        saveSyncedIDs()
    }
}

// MARK: - HistorySyncDelegate

extension iOSHistoryManager: HistorySyncDelegate {
    public func pendingEntries() -> [SyncableHistoryEntry] {
        pruneStaleSyncedIDs()
        return items
            .filter { !syncedIDs.contains($0.id) }
            .map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        if let index = items.firstIndex(where: { $0.id == entry.id }) {
            let local = items[index]
            if entry.updatedAt > local.updatedAt {
                items[index] = iOSHistoryItem.fromSyncable(entry)
                items.sort { $0.createdAt > $1.createdAt }
                saveHistory()
                syncedIDs.insert(entry.id)
            } else if entry.updatedAt == local.updatedAt {
                // An already-present duplicate is an acknowledgement.
                syncedIDs.insert(entry.id)
            } else {
                // The local entry is newer and must remain pending for upload.
                syncedIDs.remove(entry.id)
            }
            pruneStaleSyncedIDs()
            saveSyncedIDs()
            return
        }

        let item = iOSHistoryItem.fromSyncable(entry)
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        saveHistory()
        syncedIDs.insert(entry.id)
        saveSyncedIDs()
    }

    public func didDeleteRemoteEntry(id: UUID) async {
        items.removeAll { $0.id == id }
        saveHistory()
        syncedIDs.remove(id)
        saveSyncedIDs()
    }

    public func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        syncedIDs.formUnion(ids.intersection(currentItemIDs))
        pruneStaleSyncedIDs()
        saveSyncedIDs()
    }
}
#endif
