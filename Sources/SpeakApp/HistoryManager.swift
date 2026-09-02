import AppKit
import Foundation
import SpeakCore
import os.log

// Existing persistence implementation exceeds the project defaults; keep this
// explicit until it is split by responsibility in a dedicated refactor.
// swiftlint:disable file_length

// @Implement: This file persists history items to disc and is the interface to fetch a list of them, apply any filtering, sorting, or other standard functions, and surface them to the history view.

typealias HistoryFilter = HistorySearchQuery

struct HistoryStatistics: Equatable {
  let totalSessions: Int
  let cumulativeRecordingDuration: TimeInterval
  let totalSpend: Decimal
  let averageSessionLength: TimeInterval
  let sessionsWithErrors: Int
}

/// WAL entry representing a pending history operation
struct WALEntry: Codable {
  enum Operation: String, Codable {
    case append
    case update
    case remove
    case removeAll
  }

  let id: UUID
  let operation: Operation
  let item: HistoryItem?
  let timestamp: Date

  init(operation: Operation, item: HistoryItem? = nil) {
    self.id = UUID()
    self.operation = operation
    self.item = item
    self.timestamp = Date()
  }
}

extension [WALEntry] {
  /// Applies the queued operations, in order, to an item list. Shared by WAL
  /// replay and by the startup merge of mutations queued while storage was
  /// unavailable (issue #695). Appends are idempotent by item id.
  func applied(to items: [HistoryItem]) -> [HistoryItem] {
    var current = items
    for entry in self {
      switch entry.operation {
      case .append:
        if let item = entry.item, !current.contains(where: { $0.id == item.id }) {
          current.insert(item, at: 0)
        }
      case .update:
        if let item = entry.item, let index = current.firstIndex(where: { $0.id == item.id }) {
          current[index] = item
        }
      case .remove:
        if let item = entry.item {
          current.removeAll { $0.id == item.id }
        }
      case .removeAll:
        current.removeAll()
      }
    }
    return current
  }
}

/// Startup persistence state. `failed` means the on-disk history could not be
/// loaded; the last snapshot is left untouched and every operation that could
/// replace it is blocked until a retry succeeds (issue #695).
enum HistoryLoadState: Equatable {
  case loading
  case ready
  case failed(String)

  var isReady: Bool { self == .ready }
}

@MainActor
// swiftlint:disable:next type_body_length
final class HistoryManager: ObservableObject {
  @Published private(set) var items: [HistoryItem] = []
  @Published private(set) var statistics: HistoryStatistics = .init(
    totalSessions: 0,
    cumulativeRecordingDuration: 0,
    totalSpend: 0,
    averageSessionLength: 0,
    sessionsWithErrors: 0
  )
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

  private let storageURL: URL
  private let encoder: JSONEncoder
  private let log = SpeakLogger.logger(category: "HistoryManager")
  private let walStore: HistoryWALStore
  private var initialLoadTask: Task<Void, Never>?

  /// Pending writes waiting to be flushed
  private var pendingWrites: [WALEntry] = []

  /// Timer for periodic flushing
  private var flushTimer: Timer?

  /// Maximum number of pending writes before forcing a flush
  nonisolated static let defaultBatchSizeThreshold = 10

  /// Default flush interval in seconds
  nonisolated static let defaultFlushInterval: TimeInterval = 5.0

  /// Configurable flush interval
  var flushInterval: TimeInterval {
    didSet {
      scheduleFlushTimer()
    }
  }

  /// Batch size threshold for triggering flush
  var batchSizeThreshold: Int

  /// Fired after a locally created item is committed, so history sync can
  /// upload it. Wired by `MacHistorySyncAdapter` at bootstrap.
  var onItemAppended: ((HistoryItem) -> Void)?

  /// Fired after a local removal, so history sync can delete the remote copy.
  var onItemRemoved: ((UUID) -> Void)?

  /// Flag to track if we're currently flushing
  private var isFlushing = false

  /// Observer for app termination notification
  private var terminationObserver: NSObjectProtocol?

  init(fileManager: FileManager = .default, flushInterval: TimeInterval = defaultFlushInterval, batchSizeThreshold: Int = defaultBatchSizeThreshold, pageSize: Int = 50) {
    self.pageSize = pageSize
    let supportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    let appFolder = supportURL.appendingPathComponent("SpeakApp", isDirectory: true)
    let historyDir = appFolder.appendingPathComponent("History", isDirectory: true)
    if !fileManager.fileExists(atPath: historyDir.path) {
      try? fileManager.createDirectory(at: historyDir, withIntermediateDirectories: true)
    }
    storageURL = historyDir.appendingPathComponent("history-log.json", isDirectory: false)
    let walURL = historyDir.appendingPathComponent("history-wal.json", isDirectory: false)

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    self.flushInterval = flushInterval
    self.batchSizeThreshold = batchSizeThreshold
    self.walStore = HistoryWALStore(storageURL: storageURL, walURL: walURL)

    initialLoadTask = Task { [weak self] in
      guard let self else { return }
      await self.loadFromDisk()
      self.scheduleFlushTimer()
    }

    registerForTerminationNotification()
  }

  deinit {
    initialLoadTask?.cancel()
    flushTimer?.invalidate()
    if let observer = terminationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - Termination Handling

  private func registerForTerminationNotification() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { @MainActor [weak self] _ in
      guard let self else { return }
      // Termination notifications run on main thread - call sync wrapper
      self.flushImmediatelySync()
    }
  }

  // MARK: - Flush Timer Management

  private func scheduleFlushTimer() {
    flushTimer?.invalidate()
    // Use target-selector pattern to avoid Swift concurrency crashes during deallocation.
    // Block-based timers with [weak self] can crash in swift_getObjectType during executor
    // verification when the object is deallocating.
    flushTimer = Timer.scheduledTimer(
      timeInterval: flushInterval,
      target: self,
      selector: #selector(flushTimerFired),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func flushTimerFired() {
    flushIfNeededSync()
  }

  // MARK: - WAL Operations (delegated to HistoryWALStore actor)

  /// Append an entry via the isolated WAL store so FileHandle work stays
  /// off the MainActor. `pendingWrites` remains MainActor-isolated for
  /// flush bookkeeping; the on-disk append is actor-isolated.
  private func appendToWAL(_ entry: WALEntry) async {
    pendingWrites.append(entry)
    // While startup load has failed, nothing may touch the history files: the
    // entry stays queued in memory and is written after a successful retry.
    guard loadState.isReady else { return }
    do {
      try await walStore.append(entry)
    } catch {
      // The mutation is not durable yet; it remains in pendingWrites so the
      // next flush retries it through the snapshot commit.
      persistenceError = "History could not be written to disk. It will be retried automatically."
      log.error("WAL append failed: \(error.localizedDescription, privacy: .public)")
    }
    if pendingWrites.count >= batchSizeThreshold {
      await flushIfNeeded()
    }
  }

  /// Allows callers and tests to wait until startup replay has populated the
  /// in-memory view. Mutations call this before changing state so startup load
  /// can never overwrite a newly appended history item.
  func waitUntilLoaded() async {
    await initialLoadTask?.value
  }

  // MARK: - Flush Operations

  /// Flush pending writes if there are any
  private func flushIfNeeded() async {
    guard !pendingWrites.isEmpty, !isFlushing else { return }
    await flushImmediately()
  }

  /// Sync wrapper for timer callback - timer already runs on main thread
  private func flushIfNeededSync() {
    guard !pendingWrites.isEmpty, !isFlushing else { return }
    Task { [weak self] in
      await self?.flushImmediately()
    }
  }

  /// Termination flush. Runs entirely on the main actor and writes inline.
  ///
  /// The previous shape — `Task.detached { await flushImmediately() }` plus
  /// `DispatchSemaphore.wait()` — deadlocked: `flushImmediately()` is main-actor
  /// isolated, so the detached task could never enter it while the main actor was
  /// parked on the semaphore. The app then exited five seconds later with the
  /// pending writes unflushed. Doing the encode + write synchronously here costs a
  /// short stall during `willTerminate`, but actually persists the data.
  private func flushImmediatelySync() {
    // A failed startup load means the in-memory view does not contain the
    // persisted history; writing it here would replace a valid snapshot with
    // only the newest items (issue #695).
    guard loadState.isReady else { return }
    guard !pendingWrites.isEmpty, !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }

    log.info("Flushing \(self.pendingWrites.count) pending writes to disk (termination)")

    let snapshot = allItemsOnDisk.isEmpty ? items : allItemsOnDisk

    do {
      try Self.writeSnapshot(snapshot, to: storageURL, encoder: encoder)
      // Intentionally retain the WAL during termination. Replay is idempotent,
      // and an asynchronous actor cleanup is not guaranteed to run before exit.
      log.info("Termination flush complete")
    } catch {
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Force immediate flush of all pending writes — now via isolated WAL store
  func flushImmediately() async {
    await waitUntilLoaded()
    // Never replace the on-disk snapshot from a state that failed to load it.
    guard loadState.isReady else { return }
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    guard !pendingWrites.isEmpty else { return }
    log.info("Flushing \(self.pendingWrites.count) pending writes to disk")
    let snapshot = allItemsOnDisk.isEmpty ? items : allItemsOnDisk
    let flushedCount = pendingWrites.count
    let flushedEntries = Array(pendingWrites.prefix(flushedCount))
    do {
      try await walStore.commitSnapshot(snapshot, flushing: flushedEntries)
      completeFlush(flushedCount: flushedCount)
      persistenceError = nil
      log.info("Flush complete")
    } catch {
      persistenceError = "History could not be written to disk. It will be retried automatically."
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Encode + atomic write. Retained for termination path which must stay
  /// synchronous; the async path now uses `walStore.writeSnapshot`.
  private nonisolated static func writeSnapshot(
    _ items: [HistoryItem],
    to url: URL,
    encoder: JSONEncoder
  ) throws {
    let data = try encoder.encode(items)
    try data.write(to: url, options: [.atomic])
  }

  /// Post-write bookkeeping. The WAL actor has already removed exactly these
  /// entries before this method runs, so later appends remain pending and durable.
  private func completeFlush(flushedCount: Int) {
    pendingWrites.removeFirst(min(flushedCount, pendingWrites.count))
  }

  // MARK: - Public API

  func loadFromDisk() async {
    do {
      // Replay is a single actor transaction; if there is no WAL, load the
      // snapshot through the same actor so all history file I/O stays ordered.
      let persisted: [HistoryItem]
      if let replayed = try await walStore.replayWAL() {
        persisted = replayed
      } else {
        persisted = try await walStore.loadSnapshot()
      }
      // Mutations queued while the store was unavailable are replayed on top
      // of the loaded history, so a retried load keeps both (issue #695). On
      // first startup the queue is empty and this is the identity.
      let merged = pendingWrites.applied(to: persisted)
      let (sorted, stats) = await Task.detached(priority: .userInitiated) {
        let sorted = merged.sorted { $0.createdAt > $1.createdAt }
        let stats = Self.calculateStatistics(for: sorted)
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
      // Make the queued mutations durable now that the store is reachable.
      // They remain in pendingWrites either way; flush commits them.
      for entry in pendingWrites {
        try? await walStore.append(entry)
      }
      if !pendingWrites.isEmpty {
        await flushIfNeeded()
      }
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
    allItemsOnDisk.insert(item, at: 0)
    itemsByIDOnDisk[item.id] = item

    var current = items
    current.insert(item, at: 0)
    items = current

    updateStatisticsForAppend(item)
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .append, item: item))

    onItemAppended?(item)
  }

  func update(_ item: HistoryItem) async {
    await waitUntilLoaded()
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
      updateStatisticsForUpdate(oldItem: oldItem, newItem: item)
    } else {
      let stats = Self.calculateStatistics(for: allItemsOnDisk)
      cachedStatistics = stats
      statistics = stats
    }
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .update, item: item))
  }

  func remove(id: UUID) async {
    await waitUntilLoaded()
    let diskItem = allItemsOnDisk.first(where: { $0.id == id })
    allItemsOnDisk.removeAll { $0.id == id }
    itemsByIDOnDisk.removeValue(forKey: id)

    items.removeAll { $0.id == id }

    if let diskItem {
      updateStatisticsForRemove(diskItem)
    }
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    if let diskItem {
      await appendToWAL(WALEntry(operation: .remove, item: diskItem))
      onItemRemoved?(id)
    }
  }

  func removeAll() async {
    await waitUntilLoaded()
    allItemsOnDisk = []
    itemsByIDOnDisk = [:]
    items = []
    let stats = Self.calculateStatistics(for: [])
    cachedStatistics = stats
    statistics = stats
    contentRevision &+= 1

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .removeAll))
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

  /// Duration counted towards statistics for a single item, falling back to
  /// the recording phase timestamps when no explicit duration was captured.
  private nonisolated static func effectiveDuration(of item: HistoryItem) -> TimeInterval {
    if item.recordingDuration > 0 {
      return item.recordingDuration
    }
    if let start = item.phaseTimestamps.recordingStarted, let end = item.phaseTimestamps.recordingEnded {
      return max(0, end.timeIntervalSince(start))
    }
    return 0
  }

  nonisolated static func calculateStatistics(for items: [HistoryItem]) -> HistoryStatistics {
    guard !items.isEmpty else {
      return .init(
        totalSessions: 0, cumulativeRecordingDuration: 0, totalSpend: 0, averageSessionLength: 0,
        sessionsWithErrors: 0)
    }

    let totalDuration = items.reduce(0) { partial, item in
      partial + effectiveDuration(of: item)
    }
    let totalErrors = items.filter { !$0.errors.isEmpty }.count
    let totalSpend = items.reduce(Decimal(0)) { partial, item in
      if let cost = item.cost?.total {
        return partial + cost
      }
      return partial
    }

    let average = totalDuration / Double(items.count)
    return .init(
      totalSessions: items.count,
      cumulativeRecordingDuration: totalDuration,
      totalSpend: totalSpend,
      averageSessionLength: average,
      sessionsWithErrors: totalErrors
    )
  }

  // MARK: - Incremental Statistics Updates

  private func updateStatisticsForAppend(_ item: HistoryItem) {
    guard let cached = cachedStatistics else {
      cachedStatistics = Self.calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let newTotalSessions = cached.totalSessions + 1
    let newCumulativeDuration = cached.cumulativeRecordingDuration + Self.effectiveDuration(of: item)
    let newTotalSpend = cached.totalSpend + (item.cost?.total ?? 0)
    let newErrorCount = cached.sessionsWithErrors + (item.errors.isEmpty ? 0 : 1)
    let newAverageLength = newTotalSessions > 0 ? newCumulativeDuration / Double(newTotalSessions) : 0

    let updated = HistoryStatistics(
      totalSessions: newTotalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
    cachedStatistics = updated
    statistics = updated
  }

  private func updateStatisticsForRemove(_ item: HistoryItem) {
    guard let cached = cachedStatistics else {
      cachedStatistics = Self.calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let newTotalSessions = max(0, cached.totalSessions - 1)
    guard newTotalSessions > 0 else {
      // Reset exactly to the empty baseline so float drift can't accumulate.
      let empty = Self.calculateStatistics(for: [])
      cachedStatistics = empty
      statistics = empty
      return
    }
    let newCumulativeDuration = max(0, cached.cumulativeRecordingDuration - Self.effectiveDuration(of: item))
    let newTotalSpend = max(0, cached.totalSpend - (item.cost?.total ?? 0))
    let newErrorCount = max(0, cached.sessionsWithErrors - (item.errors.isEmpty ? 0 : 1))
    let newAverageLength = newCumulativeDuration / Double(newTotalSessions)

    let updated = HistoryStatistics(
      totalSessions: newTotalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
    cachedStatistics = updated
    statistics = updated
  }

  private func updateStatisticsForUpdate(oldItem: HistoryItem, newItem: HistoryItem) {
    guard let cached = cachedStatistics else {
      cachedStatistics = Self.calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let durationDelta = Self.effectiveDuration(of: newItem) - Self.effectiveDuration(of: oldItem)
    let costDelta = (newItem.cost?.total ?? 0) - (oldItem.cost?.total ?? 0)
    let errorDelta = (newItem.errors.isEmpty ? 0 : 1) - (oldItem.errors.isEmpty ? 0 : 1)

    let newCumulativeDuration = max(0, cached.cumulativeRecordingDuration + durationDelta)
    let newTotalSpend = max(0, cached.totalSpend + costDelta)
    let newErrorCount = max(0, cached.sessionsWithErrors + errorDelta)
    let newAverageLength = cached.totalSessions > 0 ? newCumulativeDuration / Double(cached.totalSessions) : 0

    let updated = HistoryStatistics(
      totalSessions: cached.totalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
    cachedStatistics = updated
    statistics = updated
  }
}

// swiftlint:enable file_length
