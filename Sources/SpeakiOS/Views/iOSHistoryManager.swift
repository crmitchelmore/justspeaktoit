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

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    private init() {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        self.fileURL = documentsURL.appendingPathComponent(
            "transcription-history.json"
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSyncedIDs()

        Task {
            await loadHistory()
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
        items.insert(item, at: 0)
        saveHistory()

        Task {
            try? await HistorySyncEngine.shared.upload(
                entry: item.toSyncable()
            )
            syncedIDs.insert(item.id)
            saveSyncedIDs()
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
        items.removeAll { $0.id == item.id }
        saveHistory()

        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
            syncedIDs.remove(item.id)
            saveSyncedIDs()
        }
    }

    /// Clears all history.
    public func clearAll() {
        let allIDs = items.map(\.id)
        items.removeAll()
        saveHistory()

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

    // MARK: - Persistence

    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try decoder.decode([iOSHistoryItem].self, from: data)
        } catch {
            print("[iOSHistoryManager] Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
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
