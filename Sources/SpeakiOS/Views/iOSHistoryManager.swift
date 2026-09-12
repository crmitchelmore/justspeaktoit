// swiftlint:disable file_length
#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import UIKit
import os.log

private let logger = SpeakLogger.logger(category: "iOSHistoryManager")

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

    private let persistence: IOSHistoryPersistence
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var isStorageReady = false
    private var syncStarted = false
    private let startSync: ((iOSHistoryManager) async -> Void)?
    private let userDefaults: UserDefaults

    /// Whether CloudKit sync is wired up. Disabled in unit tests so persistence
    /// can be exercised in isolation.
    private let syncEnabled: Bool

    /// Guards against loading twice and, crucially, against saving from an
    /// unloaded (empty) state — the root cause of background-recording history
    /// loss (see `loadHistoryFromDiskIfNeeded`).
    private var hasLoadedFromDisk = false
    private var hasAttemptedDiskLoad = false

    /// IDs of entries that have been synced to CloudKit.
    @Published private(set) var syncedIDs: Set<UUID> = []
    static let syncedIDsKey = "speak.sync.syncedHistoryIDs"

    /// Debounce interval for coalescing disk writes while remote sync delivers
    /// entries one at a time. Initial CloudKit sync used to sort + rewrite the
    /// whole history file per received entry, freezing the UI.
    static let remoteCommitDebounce: Duration = .milliseconds(250)

    /// Pending debounced commit of remote sync changes, if any.
    private var pendingRemoteCommit: Task<Void, Never>?

    /// Whether remote sync changes are waiting to be sorted and persisted.
    private var hasPendingRemoteChanges = false

    /// Lifecycle observers that flush pending changes before backgrounding or
    /// termination so a debounced commit is never lost.
    private var lifecycleObservers: [NSObjectProtocol] = []

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
    init(
        fileURL: URL, syncEnabled: Bool, userDefaults: UserDefaults = .standard,
        storageIO: IOSHistoryPersistence.StorageIO = .init(),
        startSync: ((iOSHistoryManager) async -> Void)? = nil
    ) {
        self.persistence = IOSHistoryPersistence(fileURL: fileURL, storageIO: storageIO)
        self.startSync = startSync
        self.syncEnabled = syncEnabled
        self.userDefaults = userDefaults

        loadSyncedIDs()

        // Load history *synchronously* before this initializer returns. A
        // headless Action Button recording touches `.shared` cold and then
        // immediately calls `recordTranscription`; the previous async load left
        // a window where the save ran against an empty in-memory list and wiped
        // all prior history on disk.
        loadHistoryFromDiskIfNeeded()

        registerLifecycleFlushObservers()

        startSyncIfReady()
    }

    deinit {
        pendingRemoteCommit?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func registerLifecycleFlushObservers() {
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        lifecycleObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { @MainActor [weak self] _ in
                self?.flushPendingChanges()
            }
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { @MainActor [weak self] _ in
            self?.retryPersistence()
        })
    }

    /// Forces the lazy disk load so out-of-UI readers (App Intents) see the
    /// persisted history instead of the empty pre-load state.
    public func ensureLoaded() {
        if !isStorageReady { retryPersistence() }
    }

    /// Persists any debounced remote sync changes immediately. Called from the
    /// lifecycle observers; safe to call at any time.
    public func flushPendingChanges() {
        commitRemoteChangesNow()
        if persistenceError != nil { retryPersistence() }
    }

    // MARK: - CloudKit Sync Init

    private func startSyncIfReady() {
        guard syncEnabled, isStorageReady, !syncStarted else { return }
        syncStarted = true
        Task {
            if let startSync { await startSync(self) } else { await initializeSync() }
        }
    }

    private func initializeSync() async {
        await HistorySyncEngine.shared.initialize(delegate: self)
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Public API

    /// Adds a new transcription to history.
    public func add(_ item: iOSHistoryItem) {
        _ = upsertReportingDurability(item)
    }

    /// Inserts (or replaces, by id) a history item and reports whether the
    /// write actually reached disk (issue #674): callers that must not
    /// acknowledge or delete source material until the entry is durable —
    /// the Watch import pipeline — branch on this. Replacing by id keeps
    /// duplicate imports of the same capture from creating duplicate rows.
    @discardableResult
    public func upsertReportingDurability(_ item: iOSHistoryItem) -> Bool {
        loadHistoryFromDiskIfNeeded()
        let current: iOSHistoryItem
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            current = items[index].updatedAt > item.updatedAt ? items[index] : item
            if items[index].createdAt == current.createdAt {
                items[index] = current
            } else {
                items.remove(at: index)
                let insertion = items.firstIndex { $0.createdAt < current.createdAt } ?? items.endIndex
                items.insert(current, at: insertion)
            }
        } else {
            current = item
            let index = items.firstIndex { $0.createdAt < item.createdAt } ?? items.endIndex
            items.insert(item, at: index)
        }
        persistence.remember(current)
        syncedIDs.remove(item.id)
        saveSyncedIDs()
        guard saveHistoryReportingDurability() else { return false }

        guard syncEnabled, isStorageReady else { return true }
        Task {
            do {
                try await HistorySyncEngine.shared.upload(entry: current.toSyncable())
                syncedIDs.insert(item.id)
                saveSyncedIDs()
            } catch {
                // Leave the item unsynced so a later full sync retries it,
                // rather than marking it synced after a failed upload.
                logger.error("Failed to upload item: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// Creates and adds a history item from a transcription result.
    ///
    /// Returns the item **only when the write reached disk**. Callers use the
    /// returned item to decide whether to say "Saved to History" and whether
    /// to publish a Handoff pointer at it, and neither may be claimed for an
    /// entry that exists only in this process's memory: the receipt would be
    /// false and the pointer would send a Mac to an entry that is gone after
    /// the next relaunch (issue #674's durability signal, applied to #1006 and
    /// #1008). The item stays in `items` for the current session either way,
    /// and `persistenceError` already surfaces the failure in the UI.
    @discardableResult
    public func recordTranscription(text: String, model: String, duration: TimeInterval) -> iOSHistoryItem? {
        recordTranscription(text: text, model: model, duration: duration, errorMessage: nil)
    }

    @discardableResult
    func recordTranscription(
        text: String,
        model: String,
        duration: TimeInterval,
        errorMessage: String?
    ) -> iOSHistoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let item = iOSHistoryItem(
            transcription: text,
            model: model,
            duration: duration,
            wordCount: text.split(separator: " ").count,
            errorMessage: errorMessage
        )
        guard upsertReportingDurability(item) else { return nil }
        return item
    }

    /// Removes an item from history.
    public func remove(_ item: iOSHistoryItem) {
        loadHistoryFromDiskIfNeeded()
        guard isStorageReady else { return }
        let previous = items
        items.removeAll { $0.id == item.id }
        guard saveHistoryReportingDurability() else {
            items = previous
            return
        }
        syncedIDs.remove(item.id)
        saveSyncedIDs()
        // A Handoff pointer must never outlive the entry it points at
        // (issue #1006) — deleting the advertised entry individually counts
        // just as much as clearing everything.
        TranscriptHandoffPublisher.invalidateIfAdvertising(entryID: item.id)

        guard syncEnabled else { return }
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
        }
    }

    /// Clears all history.
    public func clearAll() {
        loadHistoryFromDiskIfNeeded()
        guard isStorageReady else { return }
        let previous = items
        let allIDs = items.map(\.id)
        items.removeAll()
        guard saveHistoryReportingDurability() else {
            items = previous
            return
        }
        syncedIDs.removeAll()
        saveSyncedIDs()

        // A Handoff pointer must never outlive the entry it points at
        // (issue #1006).
        TranscriptHandoffPublisher.invalidate()
        guard syncEnabled else { return }
        Task {
            for entryID in allIDs {
                try? await HistorySyncEngine.shared.delete(entryID: entryID)
            }
        }
    }

    /// What this device can honestly say about the CloudKit lane for a capture
    /// (issue #1007). Never a claim that a Mac received anything — the phone
    /// has no evidence of that (issue #952).
    public func macLaneOutcome(for item: iOSHistoryItem?) -> MacLaneOutcome {
        guard item != nil, syncEnabled else { return .notAttempted }
        return HistorySyncEngine.shared.state.isCloudAvailable ? .queuedForICloud : .iCloudUnavailable
    }

    /// Trigger a manual sync.
    public func triggerSync() async {
        retryPersistence()
        guard syncEnabled, isStorageReady else { return }
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
        setPostProcessed(processed, for: id, preservingError: nil)
    }

    func setPostProcessed(_ processed: String, for id: UUID, preservingError: String?) {
        loadHistoryFromDiskIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let updated = items[index].withPostProcessed(processed).withError(preservingError)
        reprocessingIDs.remove(id)
        upsertReportingDurability(updated)
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
        persistence.remember(items[index])
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
        guard !hasAttemptedDiskLoad else { return }
        hasAttemptedDiskLoad = true
        items = persistence.load(visible: items)
        refreshPersistenceState()
        if isStorageReady {
            syncedIDs.subtract(persistence.recoveredIDs)
            pruneStaleSyncedIDs()
            saveSyncedIDs()
        }
        startSyncIfReady()
    }

    public func retryPersistence() {
        if !isStorageReady {
            hasAttemptedDiskLoad = false
            loadHistoryFromDiskIfNeeded()
        } else {
            saveHistory()
        }
    }

    private func refreshPersistenceState() {
        isStorageReady = persistence.isReady
        hasLoadedFromDisk = isStorageReady
        persistenceError = persistence.errorMessage
    }

    private func saveHistory() {
        _ = saveHistoryReportingDurability()
    }

    @discardableResult
    private func saveHistoryReportingDurability() -> Bool {
        let durable = persistence.save(items)
        refreshPersistenceState()
        startSyncIfReady()
        return durable
    }

    // MARK: - Batched Remote Commits

    /// Marks remote sync changes as pending and (re)starts the debounce timer.
    /// Remote entries arrive one at a time from the sync engine; batching them
    /// into a single sort + save keeps the initial sync from rewriting the
    /// history file per entry.
    private func scheduleRemoteCommit() {
        hasPendingRemoteChanges = true
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = Task { [weak self] in
            try? await Task.sleep(for: Self.remoteCommitDebounce)
            guard !Task.isCancelled else { return }
            self?.commitRemoteChangesNow()
        }
    }

    /// Sorts once and persists once for however many remote changes accumulated.
    @discardableResult
    private func commitRemoteChangesNow() -> Bool {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = nil
        guard hasPendingRemoteChanges else { return true }

        items.sort { $0.createdAt > $1.createdAt }
        guard saveHistoryReportingDurability() else { return false }
        hasPendingRemoteChanges = false
        pruneStaleSyncedIDs()
        saveSyncedIDs()
        return true
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

extension iOSHistoryManager: HistorySyncDurabilityDelegate {
    public func persistRemoteChanges() async throws {
        guard commitRemoteChangesNow() else { throw CocoaError(.fileWriteUnknown) }
    }

    public func pendingEntries() -> [SyncableHistoryEntry] {
        pruneStaleSyncedIDs()
        return items
            .filter { !syncedIDs.contains($0.id) }
            .map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        // Mutate in memory only; sorting and persisting are debounced so a
        // burst of remote entries costs one sort + one save, not one each.
        if let index = items.firstIndex(where: { $0.id == entry.id }) {
            let local = items[index]
            if entry.updatedAt > local.updatedAt {
                items[index] = iOSHistoryItem.fromSyncable(entry)
                persistence.remember(items[index])
                syncedIDs.insert(entry.id)
            } else if entry.updatedAt == local.updatedAt {
                // An already-present duplicate is an acknowledgement.
                syncedIDs.insert(entry.id)
            } else {
                // The local entry is newer and must remain pending for upload.
                syncedIDs.remove(entry.id)
            }
            scheduleRemoteCommit()
            return
        }

        let item = iOSHistoryItem.fromSyncable(entry)
        items.insert(item, at: 0)
        persistence.remember(item)
        syncedIDs.insert(entry.id)
        scheduleRemoteCommit()
    }

    public func didDeleteRemoteEntry(id: UUID) async {
        // Tombstones are rare and must be observable immediately (including
        // the persisted acknowledgement set), so they bypass the debounced
        // remote-commit path used for entry bursts.
        items.removeAll { $0.id == id }
        persistence.rememberDeletion(id)
        syncedIDs.remove(id)
        hasPendingRemoteChanges = true
        commitRemoteChangesNow()
        // Same rule as a local delete: the pointer cannot outlive its entry
        // (issue #1006). A remote tombstone is still a deliberate deletion.
        TranscriptHandoffPublisher.invalidateIfAdvertising(entryID: id)
    }

    public func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        guard commitRemoteChangesNow() else { return }
        syncedIDs.formUnion(ids.intersection(currentItemIDs))
        pruneStaleSyncedIDs()
        saveSyncedIDs()
    }
}
#endif
