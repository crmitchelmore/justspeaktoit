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

  let pageSize: Int

  /// Full list of items loaded from disk (for pagination)
  private var allItemsOnDisk: [HistoryItem] = []

  /// All known items (used for charts / totals). Falls back to the currently loaded page during startup.
  var allItems: [HistoryItem] {
    allItemsOnDisk.isEmpty ? items : allItemsOnDisk
  }

  /// Cached statistics to avoid recalculating
  private var cachedStatistics: HistoryStatistics?

  private let storageURL: URL
  private let walURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let log = Logger(subsystem: "com.github.speakapp", category: "HistoryManager")
  private let walStore: HistoryWALStore

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
    walURL = historyDir.appendingPathComponent("history-wal.json", isDirectory: false)

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    self.flushInterval = flushInterval
    self.batchSizeThreshold = batchSizeThreshold
    self.walStore = HistoryWALStore(
        storageURL: storageURL, walURL: walURL, encoder: encoder, decoder: decoder)

    Task {
      await loadFromDisk()
      scheduleFlushTimer()
    }

    registerForTerminationNotification()
  }

  deinit {
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
    await walStore.append(entry)
    if pendingWrites.count >= batchSizeThreshold {
      await flushIfNeeded()
    }
  }

  private func clearWAL() async {
    await walStore.clear()
  }

  private func rewriteWAL(with entries: [WALEntry]) async {
    await walStore.rewrite(with: entries)
  }

  /// Replay WAL entries and merge into main storage via the isolated store.
  private func replayWAL() async -> [HistoryItem] {
    do {
      let walEntries = try await walStore.loadWALEntries()
      if walEntries.isEmpty { return [] }
      log.info("Replaying \(walEntries.count) WAL entries")
      var currentItems = try await walStore.loadSnapshot()
      for entry in walEntries {
        switch entry.operation {
        case .append:
          if let item = entry.item, !currentItems.contains(where: { $0.id == item.id }) {
            currentItems.insert(item, at: 0)
          }
        case .update:
          if let item = entry.item, let index = currentItems.firstIndex(where: { $0.id == item.id }) {
            currentItems[index] = item
          }
        case .remove:
          if let item = entry.item { currentItems.removeAll { $0.id == item.id } }
        case .removeAll:
          currentItems.removeAll()
        }
      }
      try await walStore.writeSnapshot(currentItems)
      await walStore.clear()
      log.info("WAL replay complete, cleared WAL file")
      return currentItems
    } catch {
      log.error("Failed to replay WAL: \(error.localizedDescription, privacy: .public)")
      return []
    }
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
    Task.detached { [weak self] in
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
    guard !pendingWrites.isEmpty, !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }

    log.info("Flushing \(self.pendingWrites.count) pending writes to disk (termination)")

    let snapshot = allItemsOnDisk.isEmpty ? items : allItemsOnDisk
    let flushedCount = pendingWrites.count

    do {
      try Self.writeSnapshot(snapshot, to: storageURL, encoder: encoder)
      completeFlush(flushedCount: flushedCount)
      log.info("Termination flush complete")
    } catch {
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Force immediate flush of all pending writes — now via isolated WAL store
  func flushImmediately() async {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    guard !pendingWrites.isEmpty else { return }
    log.info("Flushing \(self.pendingWrites.count) pending writes to disk")
    let snapshot = allItemsOnDisk.isEmpty ? items : allItemsOnDisk
    let flushedCount = pendingWrites.count
    do {
      try await walStore.writeSnapshot(snapshot)
      completeFlush(flushedCount: flushedCount)
      log.info("Flush complete")
    } catch {
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

  /// Post-write bookkeeping. Drops only the writes covered by the snapshot;
  /// anything appended while the write was in flight stays pending (and stays
  /// in the WAL). WAL cleanup is now properly awaited.
  private func completeFlush(flushedCount: Int) {
    pendingWrites.removeFirst(min(flushedCount, pendingWrites.count))
    if pendingWrites.isEmpty {
      Task { await self.clearWAL() }
    } else {
      let remaining = pendingWrites
      Task { await self.rewriteWAL(with: remaining) }
    }
  }

  // MARK: - Public API

  func loadFromDisk() async {
    // First replay any WAL entries from a previous crash
    let walItems = await replayWAL()

    do {
      if !walItems.isEmpty {
        // Sort and calculate stats in background
        let (sorted, stats) = await Task.detached(priority: .userInitiated) {
          let sorted = walItems.sorted { $0.createdAt > $1.createdAt }
          let stats = Self.calculateStatistics(for: sorted)
          return (sorted, stats)
        }.value
        
        await MainActor.run {
          self.allItemsOnDisk = sorted
          self.items = Array(sorted.prefix(self.pageSize))
          self.hasMoreItems = sorted.count > self.pageSize
          self.cachedStatistics = stats
          self.statistics = stats
        }
        return
      }

      guard FileManager.default.fileExists(atPath: storageURL.path) else {
        await MainActor.run {
          self.allItemsOnDisk = []
          self.items = []
          self.hasMoreItems = false
          self.cachedStatistics = Self.calculateStatistics(for: [])
          self.statistics = self.cachedStatistics!
        }
        return
      }
      
      // Load and decode in background to avoid blocking UI
      let url = storageURL
      let (sorted, stats) = try await Task.detached(priority: .userInitiated) { [decoder] in
        let data = try Data(contentsOf: url)
        let decoded = try decoder.decode([HistoryItem].self, from: data)
        let sorted = decoded.sorted { $0.createdAt > $1.createdAt }
        let stats = Self.calculateStatistics(for: sorted)
        return (sorted, stats)
      }.value

      await MainActor.run {
        self.allItemsOnDisk = sorted
        self.items = Array(sorted.prefix(self.pageSize))
        self.hasMoreItems = sorted.count > self.pageSize
        self.cachedStatistics = stats
        self.statistics = stats
      }
    } catch {
      log.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
    }
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
    allItemsOnDisk.insert(item, at: 0)

    var current = items
    current.insert(item, at: 0)
    items = current

    updateStatisticsForAppend(item)

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .append, item: item))
  }

  func update(_ item: HistoryItem) async {
    var oldItem: HistoryItem?
    if let diskIndex = allItemsOnDisk.firstIndex(where: { $0.id == item.id }) {
      oldItem = allItemsOnDisk[diskIndex]
      allItemsOnDisk[diskIndex] = item
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

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .update, item: item))
  }

  func remove(id: UUID) async {
    let diskItem = allItemsOnDisk.first(where: { $0.id == id })
    allItemsOnDisk.removeAll { $0.id == id }

    items.removeAll { $0.id == id }

    if let diskItem {
      updateStatisticsForRemove(diskItem)
    }

    // Write to WAL instead of directly to disk
    if let diskItem {
      await appendToWAL(WALEntry(operation: .remove, item: diskItem))
    }
  }

  func removeAll() async {
    allItemsOnDisk = []
    items = []
    let stats = Self.calculateStatistics(for: [])
    cachedStatistics = stats
    statistics = stats

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
