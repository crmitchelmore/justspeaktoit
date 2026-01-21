import AppKit
import Foundation
import os.log

// @Implement: This file persists history items to disc and is the interface to fetch a list of them, apply any filtering, sorting, or other standard functions, and surface them to the history view.

struct HistoryFilter: Equatable {
  var searchText: String?
  var modelIdentifiers: Set<String> = []
  var includeErrorsOnly: Bool = false
  var dateRange: ClosedRange<Date>?

  static let none = HistoryFilter()
}

struct HistoryStatistics: Equatable {
  let totalSessions: Int
  let cumulativeRecordingDuration: TimeInterval
  let totalSpend: Decimal
  let averageSessionLength: TimeInterval
  let sessionsWithErrors: Int
}

/// WAL entry representing a pending history operation
private struct WALEntry: Codable {
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
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        await self.flushImmediately()
      }
    }
  }

  // MARK: - Flush Timer Management

  private func scheduleFlushTimer() {
    flushTimer?.invalidate()
    flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        await self.flushIfNeeded()
      }
    }
  }

  // MARK: - WAL Operations

  /// Append an entry to the WAL file
  private func appendToWAL(_ entry: WALEntry) async {
    pendingWrites.append(entry)

    do {
      var walEntries: [WALEntry] = []
      if FileManager.default.fileExists(atPath: walURL.path) {
        let data = try Data(contentsOf: walURL)
        walEntries = (try? decoder.decode([WALEntry].self, from: data)) ?? []
      }
      walEntries.append(entry)
      let data = try encoder.encode(walEntries)
      try data.write(to: walURL, options: [.atomic])
    } catch {
      log.error("Failed to append to WAL: \(error.localizedDescription, privacy: .public)")
    }

    // Check if we should flush based on batch size
    if pendingWrites.count >= batchSizeThreshold {
      await flushIfNeeded()
    }
  }

  /// Replay WAL entries and merge into main storage
  private func replayWAL() async -> [HistoryItem] {
    guard FileManager.default.fileExists(atPath: walURL.path) else {
      return []
    }

    do {
      let data = try Data(contentsOf: walURL)
      let walEntries = try decoder.decode([WALEntry].self, from: data)

      if walEntries.isEmpty {
        return []
      }

      log.info("Replaying \(walEntries.count) WAL entries")

      // Load current items from disk
      var currentItems: [HistoryItem] = []
      if FileManager.default.fileExists(atPath: storageURL.path) {
        let storageData = try Data(contentsOf: storageURL)
        currentItems = (try? decoder.decode([HistoryItem].self, from: storageData)) ?? []
      }

      // Apply WAL entries
      for entry in walEntries {
        switch entry.operation {
        case .append:
          if let item = entry.item {
            // Check for duplicates
            if !currentItems.contains(where: { $0.id == item.id }) {
              currentItems.insert(item, at: 0)
            }
          }
        case .update:
          if let item = entry.item,
             let index = currentItems.firstIndex(where: { $0.id == item.id }) {
            currentItems[index] = item
          }
        case .remove:
          if let item = entry.item {
            currentItems.removeAll { $0.id == item.id }
          }
        case .removeAll:
          currentItems.removeAll()
        }
      }

      // Persist merged state
      let mergedData = try encoder.encode(currentItems)
      try mergedData.write(to: storageURL, options: [.atomic])

      // Clear WAL after successful merge
      try FileManager.default.removeItem(at: walURL)

      log.info("WAL replay complete, cleared WAL file")

      return currentItems

    } catch {
      log.error("Failed to replay WAL: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  /// Clear the WAL file
  private func clearWAL() {
    do {
      if FileManager.default.fileExists(atPath: walURL.path) {
        try FileManager.default.removeItem(at: walURL)
      }
    } catch {
      log.error("Failed to clear WAL: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Flush Operations

  /// Flush pending writes if there are any
  private func flushIfNeeded() async {
    guard !pendingWrites.isEmpty, !isFlushing else { return }
    await flushImmediately()
  }

  /// Force immediate flush of all pending writes
  func flushImmediately() async {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }

    guard !pendingWrites.isEmpty else { return }

    log.info("Flushing \(self.pendingWrites.count) pending writes to disk")

    do {
      // Persist the full history, not just the currently loaded page.
      let snapshot = allItemsOnDisk.isEmpty ? items : allItemsOnDisk
      let data = try encoder.encode(snapshot)
      try data.write(to: storageURL, options: [.atomic])

      // Clear pending writes and WAL after successful persist
      pendingWrites.removeAll()
      clearWAL()

      log.info("Flush complete")
    } catch {
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Public API

  func loadFromDisk() async {
    // First replay any WAL entries from a previous crash
    let walItems = await replayWAL()

    do {
      if !walItems.isEmpty {
        let sorted = walItems.sorted { $0.createdAt > $1.createdAt }
        let stats = calculateStatistics(for: sorted)
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
          self.cachedStatistics = self.calculateStatistics(for: [])
          self.statistics = self.cachedStatistics!
        }
        return
      }
      let data = try Data(contentsOf: storageURL)
      let decoded = try decoder.decode([HistoryItem].self, from: data)
      let sorted = decoded.sorted { $0.createdAt > $1.createdAt }
      let stats = calculateStatistics(for: sorted)

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

    let stats = calculateStatistics(for: allItemsOnDisk)
    cachedStatistics = stats
    statistics = stats

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .append, item: item))
  }

  func update(_ item: HistoryItem) async {
    if let diskIndex = allItemsOnDisk.firstIndex(where: { $0.id == item.id }) {
      allItemsOnDisk[diskIndex] = item
      allItemsOnDisk.sort { $0.createdAt > $1.createdAt }
    }

    if let index = items.firstIndex(where: { $0.id == item.id }) {
      var updated = items
      updated[index] = item
      items = updated.sorted { $0.createdAt > $1.createdAt }
    }

    let stats = calculateStatistics(for: allItemsOnDisk)
    cachedStatistics = stats
    statistics = stats

    // Write to WAL instead of directly to disk
    await appendToWAL(WALEntry(operation: .update, item: item))
  }

  func remove(id: UUID) async {
    let diskItem = allItemsOnDisk.first(where: { $0.id == id })
    allItemsOnDisk.removeAll { $0.id == id }

    items.removeAll { $0.id == id }

    let stats = calculateStatistics(for: allItemsOnDisk)
    cachedStatistics = stats
    statistics = stats

    // Write to WAL instead of directly to disk
    if let diskItem {
      await appendToWAL(WALEntry(operation: .remove, item: diskItem))
    }
  }

  func removeAll() async {
    allItemsOnDisk = []
    items = []
    let stats = calculateStatistics(for: [])
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
    // Filter from the currently loaded items only
    items.filter { item in
      if let text = filter.searchText?.lowercased(), !text.isEmpty {
        let combined = [item.rawTranscription, item.postProcessedTranscription]
          .compactMap { $0?.lowercased() }
          .joined(separator: "\n")
        if !combined.contains(text) {
          return false
        }
      }

      if !filter.modelIdentifiers.isEmpty,
        filter.modelIdentifiers.intersection(item.modelsUsed).isEmpty
      {
        return false
      }

      if filter.includeErrorsOnly && item.errors.isEmpty {
        return false
      }

      if let range = filter.dateRange {
        if !range.contains(item.createdAt) {
          return false
        }
      }

      return true
    }
  }

  private func calculateStatistics(for items: [HistoryItem]) -> HistoryStatistics {
    guard !items.isEmpty else {
      return .init(
        totalSessions: 0, cumulativeRecordingDuration: 0, totalSpend: 0, averageSessionLength: 0,
        sessionsWithErrors: 0)
    }

    let totalDuration = items.reduce(0) { partial, item in
      if item.recordingDuration > 0 {
        return partial + item.recordingDuration
      }
      if let start = item.phaseTimestamps.recordingStarted, let end = item.phaseTimestamps.recordingEnded {
        return partial + max(0, end.timeIntervalSince(start))
      }
      return partial
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
      cachedStatistics = calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let newTotalSessions = cached.totalSessions + 1
    let newCumulativeDuration = cached.cumulativeRecordingDuration + item.recordingDuration
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
      cachedStatistics = calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let newTotalSessions = max(0, cached.totalSessions - 1)
    let newCumulativeDuration = max(0, cached.cumulativeRecordingDuration - item.recordingDuration)
    let newTotalSpend = max(0, cached.totalSpend - (item.cost?.total ?? 0))
    let newErrorCount = max(0, cached.sessionsWithErrors - (item.errors.isEmpty ? 0 : 1))
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

  private func updateStatisticsForUpdate(oldItem: HistoryItem, newItem: HistoryItem) {
    guard let cached = cachedStatistics else {
      cachedStatistics = calculateStatistics(for: allItemsOnDisk)
      statistics = cachedStatistics!
      return
    }

    let durationDelta = newItem.recordingDuration - oldItem.recordingDuration
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
