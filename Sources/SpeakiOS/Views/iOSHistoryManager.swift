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
    init(fileURL: URL, syncEnabled: Bool) {
        self.fileURL = fileURL
        self.syncEnabled = syncEnabled

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
        saveHistory()

        guard syncEnabled else { return }
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
            syncedIDs.remove(item.id)
            saveSyncedIDs()
        }
    }

    /// Clears all history.
    public func clearAll() {
        loadHistoryFromDiskIfNeeded()
        let allIDs = items.map(\.id)
        items.removeAll()
        saveHistory()

        guard syncEnabled else { return }
        Task {
            for entryID in allIDs {
                try? await HistorySyncEngine.shared.delete(entryID: entryID)
            }
            syncedIDs.removeAll()
            saveSyncedIDs()
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
        Task {
            try? await HistorySyncEngine.shared.upload(entry: entry)
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
        items
            .filter { !syncedIDs.contains($0.id) }
            .map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) {
        guard !items.contains(where: { $0.id == entry.id }) else {
            return
        }

        let item = iOSHistoryItem.fromSyncable(entry)
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        saveHistory()
        syncedIDs.insert(entry.id)
        saveSyncedIDs()
    }

    public func didDeleteRemoteEntry(id: UUID) {
        items.removeAll { $0.id == id }
        saveHistory()
        syncedIDs.remove(id)
        saveSyncedIDs()
    }
}
#endif
