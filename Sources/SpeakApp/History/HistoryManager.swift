import AppKit
import Foundation
import SpeakCore
import os.log

// @Implement: This file persists history items to disc and is the interface to fetch a list of them, apply any
// filtering, sorting, or other standard functions, and surface them to the history view.

typealias HistoryFilter = HistorySearchQuery

@MainActor
final class HistoryManager: ObservableObject {
  @Published private(set) var items: [HistoryItem] = []
  @Published private(set) var statistics: HistoryStatistics = .empty
  @Published private(set) var hasMoreItems: Bool = false
  @Published private(set) var isLoadingMore: Bool = false

  /// Startup persistence state. While `.failed`, mutations stay queued in
  /// memory and nothing on disk is replaced; `retryLoad()` re-attempts.
  @Published private(set) var loadState: HistoryLoadState = .loading

  /// Most recent WAL/flush failure, for the UI. Cleared by the next durable
  /// write. Never contains transcript text or file paths.
  @Published private(set) var persistenceError: String?

  /// Monotonic revision bumped on every mutation of history content (load,
  /// append, update, remove, clear-all — including CloudKit-driven merges,
  /// which land through the same mutators). Derived views that depend on
  /// record *content* (e.g. Speech Insights) should key their refresh on this
  /// rather than `statistics`, which ignores transcript text and so misses
  /// in-place edits that leave count/duration/cost unchanged.
  @Published private(set) var contentRevision: UInt64 = 0

  let pageSize: Int

  /// Full list of items loaded from disk (for pagination)
  private var allItemsOnDisk: [HistoryItem] = []

  /// `allItemsOnDisk` indexed by id, maintained by the same mutators that
  /// change the array so a lookup by id does not scan the whole history.
  private var itemsByIDOnDisk: [UUID: HistoryItem] = [:]

  /// All known items (used for charts / totals). Falls back to the currently loaded page during startup.
  var allItems: [HistoryItem] {
    allItemsOnDisk.isEmpty ? items : allItemsOnDisk
  }

  /// The item with `id` from `allItems`, without scanning it.
  ///
  /// Mirrors `allItems` branch for branch: the on-disk list is served from the
  /// id index, and the startup fallback searches the loaded page (which is
  /// empty whenever the on-disk list is).
  func item(id: UUID) -> HistoryItem? {
    if allItemsOnDisk.isEmpty {
      return items.first { $0.id == id }
    }
    return itemsByIDOnDisk[id]
  }

  /// Cached statistics to avoid recalculating
  private var cachedStatistics: HistoryStatistics?

  private let log = SpeakLogger.logger(category: "HistoryManager")
  private let persistence: HistoryPersistence
  private var initialLoadTask: Task<Void, Never>?

  /// Maximum number of pending writes before forcing a flush
  nonisolated static let defaultBatchSizeThreshold = 10

  /// Default flush interval in seconds
  nonisolated static let defaultFlushInterval: TimeInterval = 5.0

  private let automationFeed = HistoryAutomationCaptureFeed()

  /// Append-only in-memory cursor; reset with this History/server lifetime, never a persisted sync cursor.
  var automationAppendRevision: UInt64 { automationFeed.appendRevision }

  func prepareForAutomationObservation() async {
    await waitUntilLoaded()
    await waitForMigration()
  }

  func observeAutomationCapture(_ observer: @escaping (HistoryAutomationCaptureFeed.Completion) -> Void) -> UUID {
    automationFeed.observe(observer)
  }

  func removeAutomationCaptureObserver(_ token: UUID) {
    automationFeed.removeObserver(token)
  }

  /// Called only by the local capture owner after its final append/outcome, never by sync or edits.
  /// The existing WAL recovery contract remains unchanged; this is not a forced disk-flush receipt.
  func finishAutomationCapture(id: UUID, item: HistoryItem?) {
    automationFeed.finish(captureID: id, item: item)
  }

  /// Fired after a locally created item is committed, so history sync can
  /// upload it. Wired by `MacHistorySyncAdapter` at bootstrap.
  var onItemAppended: ((HistoryItem) -> Void)?

  /// Fired after a local removal, so history sync can delete the remote copy.
  var onItemRemoved: ((UUID) -> Void)?

  private var migrationInProgress = false
  private var migrationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    fileManager: FileManager = .default,
    flushInterval: TimeInterval = defaultFlushInterval,
    batchSizeThreshold: Int = defaultBatchSizeThreshold,
    pageSize: Int = 50
  ) {
    self.pageSize = pageSize
    let supportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let appFolder = supportURL.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    let historyDir = appFolder.appendingPathComponent("History", isDirectory: true)
    if !fileManager.fileExists(atPath: historyDir.path) {
      try? fileManager.createDirectory(at: historyDir, withIntermediateDirectories: true)
    }
    persistence = HistoryPersistence(
      storageURL: historyDir.appendingPathComponent("history-log.json", isDirectory: false),
      walURL: historyDir.appendingPathComponent("history-wal.json", isDirectory: false),
      flushInterval: flushInterval,
      batchSizeThreshold: batchSizeThreshold
    )
    persistence.host = self

    initialLoadTask = Task { [weak self] in
      guard let self else { return }
      await self.loadFromDisk()
      self.persistence.scheduleFlushTimer()
    }
  }

  deinit {
    initialLoadTask?.cancel()
  }

  /// Allows callers and tests to wait until startup replay has populated the
  /// in-memory view. Mutations call this before changing state so startup load
  /// can never overwrite a newly appended history item.
  func waitUntilLoaded() async {
    await initialLoadTask?.value
  }

  /// Force immediate flush of all pending writes.
  func flushImmediately() async {
    await persistence.flushImmediately()
  }

  // MARK: - Public API

  func loadFromDisk() async {
    do {
      // Mutations queued while the store was unavailable are replayed on top
      // of the loaded history, so a retried load keeps both (issue #695).
      let merged = try await persistence.load()
      let (sorted, stats) = await Task.detached(priority: .userInitiated) {
        let sorted = merged.sorted { $0.createdAt > $1.createdAt }
        let stats = HistoryStatistics.calculate(for: sorted)
        return (sorted, stats)
      }.value

      allItemsOnDisk = sorted
      itemsByIDOnDisk = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      items = Array(sorted.prefix(pageSize))
      hasMoreItems = sorted.count > pageSize
      cachedStatistics = stats
      statistics = stats
      contentRevision &+= 1
      loadState = .ready
      await persistence.persistQueuedWrites()
    } catch {
      // Leave the last snapshot and the in-memory queue untouched: readiness
      // is explicit, not inferred from task completion (issue #695).
      loadState = .failed(error.localizedDescription)
      persistenceError = "History could not be loaded from disk. New sessions are kept in memory until retry succeeds."
      log.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Re-attempts a failed startup load. Queued mutations are preserved and
  /// replayed over the loaded history on success.
  func retryLoad() async {
    guard case .failed = loadState else { return }
    loadState = .loading
    await loadFromDisk()
  }

  /// Loads more items for infinite scroll
  func loadMore() async {
    guard hasMoreItems, !isLoadingMore else { return }

    await MainActor.run {
      self.isLoadingMore = true
    }

    // Simulate async work to avoid blocking UI
    let currentCount = items.count
    let nextBatch = Array(allItemsOnDisk.dropFirst(currentCount).prefix(pageSize))
    let newTotal = currentCount + nextBatch.count
    let moreAvailable = newTotal < allItemsOnDisk.count

    await MainActor.run {
      self.items.append(contentsOf: nextBatch)
      self.hasMoreItems = moreAvailable
      self.isLoadingMore = false
    }
  }

  func append(_ item: HistoryItem) async {
    await waitUntilLoaded()
    await waitForMigration()
    allItemsOnDisk.insert(item, at: 0)
    itemsByIDOnDisk[item.id] = item

    var current = items
    current.insert(item, at: 0)
    items = current

    updateStatistics { $0.appending(item) }
    automationFeed.recordAppend()
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await persistence.record(WALEntry(operation: .append, item: item))

    onItemAppended?(item)
  }

  func update(_ item: HistoryItem) async {
    await waitUntilLoaded()
    await waitForMigration()
    var oldItem: HistoryItem?
    if let diskIndex = allItemsOnDisk.firstIndex(where: { $0.id == item.id }) {
      oldItem = allItemsOnDisk[diskIndex]
      allItemsOnDisk[diskIndex] = item
      itemsByIDOnDisk[item.id] = item
      allItemsOnDisk.sort { $0.createdAt > $1.createdAt }
    }

    if let index = items.firstIndex(where: { $0.id == item.id }) {
      var updated = items
      updated[index] = item
      items = updated.sorted { $0.createdAt > $1.createdAt }
    }

    if let oldItem {
      updateStatistics { $0.replacing(oldItem, with: item) }
    } else {
      let stats = HistoryStatistics.calculate(for: allItemsOnDisk)
      cachedStatistics = stats
      statistics = stats
    }
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await persistence.record(WALEntry(operation: .update, item: item))
  }

  func remove(id: UUID) async {
    await waitUntilLoaded()
    await waitForMigration()
    let diskItem = allItemsOnDisk.first(where: { $0.id == id })
    allItemsOnDisk.removeAll { $0.id == id }
    itemsByIDOnDisk.removeValue(forKey: id)

    items.removeAll { $0.id == id }

    if let diskItem {
      updateStatistics { $0.removing(diskItem) }
    }
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    if let diskItem {
      await persistence.record(WALEntry(operation: .remove, item: diskItem))
      onItemRemoved?(id)
    }
  }

  func removeAll() async {
    await waitUntilLoaded()
    await waitForMigration()
    allItemsOnDisk = []
    itemsByIDOnDisk = [:]
    items = []
    cachedStatistics = .empty
    statistics = .empty
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await persistence.record(WALEntry(operation: .removeAll))
  }

  func deleteHistoryItem(_ item: HistoryItem) async {
    await remove(id: item.id)
  }

  func playAudio(for item: HistoryItem) {
    guard let url = item.audioFileURL else { return }
    NSWorkspace.shared.open(url)
  }

  func showInFinder(for item: HistoryItem) {
    guard let url = item.audioFileURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func items(matching filter: HistoryFilter) -> [HistoryItem] {
    items.filter { filter.matches($0.presentationItem) }
  }

  /// Applies an incremental change to the cached statistics, or recomputes
  /// them from the full history when nothing is cached yet.
  private func updateStatistics(_ change: (HistoryStatistics) -> HistoryStatistics) {
    let updated = cachedStatistics.map(change) ?? HistoryStatistics.calculate(for: allItemsOnDisk)
    cachedStatistics = updated
    statistics = updated
  }
}

extension HistoryManager {
  var migrationSupportDirectory: URL { persistence.storageURL.deletingLastPathComponent().deletingLastPathComponent() }

  private func waitForMigration() async {
    if migrationInProgress {
      await withCheckedContinuation { migrationWaiters.append($0) }
    }
  }

  func beginDataMigration() async throws {
    await waitUntilLoaded()
    guard loadState.isReady, !migrationInProgress, !persistence.isFlushing else {
      throw MigrationError.invalid("History is saving or another import is running. Please retry.")
    }
    migrationInProgress = true
  }

  func endDataMigration() {
    migrationInProgress = false
    let waiters = migrationWaiters
    migrationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func applyMigrationSnapshot(_ snapshot: [HistoryItem]) async throws {
    await waitUntilLoaded()
    guard loadState.isReady, !persistence.isFlushing else {
      throw MigrationError.invalid("History is currently saving. Please retry the import.")
    }
    let ownsLock = !migrationInProgress
    migrationInProgress = true
    defer {
      if ownsLock { endDataMigration() }
    }
    let snapshot = Array(Dictionary(snapshot.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first }).values)
    let previous = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let oldIDs = Set(previous.keys)
    try await persistence.commitMigrationSnapshot(snapshot)
    allItemsOnDisk = snapshot.sorted { $0.createdAt > $1.createdAt }
    itemsByIDOnDisk = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    items = Array(allItemsOnDisk.prefix(pageSize))
    hasMoreItems = allItemsOnDisk.count > items.count
    statistics = HistoryStatistics.calculate(for: snapshot)
    cachedStatistics = statistics
    persistenceError = nil
    contentRevision &+= 1
    for id in oldIDs.subtracting(snapshot.map(\.id)) { onItemRemoved?(id) }
    for item in snapshot where previous[item.id] != item { onItemAppended?(item) }
  }
}

extension HistoryManager: HistoryPersistenceHost {
  var persistenceSnapshot: [HistoryItem] { allItems }
  var acceptsPersistenceWrites: Bool { loadState.isReady }
  var isMigratingHistory: Bool { migrationInProgress }

  func persistenceErrorDidChange(_ message: String?) {
    persistenceError = message
  }
}
