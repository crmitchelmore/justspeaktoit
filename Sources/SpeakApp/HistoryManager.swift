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

/// Lightweight metadata for calculating statistics without loading full items
private struct HistoryItemMetadata: Codable {
  let id: UUID
  let createdAt: Date
  let recordingDuration: TimeInterval
  let costTotal: Decimal?
  let hasErrors: Bool
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

  private let storageURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let log = Logger(subsystem: "com.github.speakapp", category: "HistoryManager")

  /// All items stored on disk, sorted by createdAt descending
  private var allItemsOnDisk: [HistoryItem] = []
  /// Cached statistics calculated from all items
  private var cachedStatistics: HistoryStatistics?

  init(fileManager: FileManager = .default, pageSize: Int = 50) {
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

    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    Task {
      await loadFromDisk()
    }
  }

  func loadFromDisk() async {
    do {
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
    // Insert into full list at beginning
    allItemsOnDisk.insert(item, at: 0)

    // Update displayed items (prepend to visible list)
    items.insert(item, at: 0)

    // Recalculate statistics incrementally
    updateStatisticsForAppend(item)

    // Update hasMoreItems based on new counts
    hasMoreItems = items.count < allItemsOnDisk.count

    await persist(items: allItemsOnDisk)
  }

  func update(_ item: HistoryItem) async {
    // Update in full list
    if let diskIndex = allItemsOnDisk.firstIndex(where: { $0.id == item.id }) {
      let oldItem = allItemsOnDisk[diskIndex]
      allItemsOnDisk[diskIndex] = item
      allItemsOnDisk.sort { $0.createdAt > $1.createdAt }

      // Update statistics incrementally
      updateStatisticsForUpdate(oldItem: oldItem, newItem: item)
    }

    // Update in displayed items if visible
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
      items.sort { $0.createdAt > $1.createdAt }
    }

    await persist(items: allItemsOnDisk)
  }

  func remove(id: UUID) async {
    // Remove from full list and update statistics
    if let diskIndex = allItemsOnDisk.firstIndex(where: { $0.id == id }) {
      let removedItem = allItemsOnDisk[diskIndex]
      allItemsOnDisk.remove(at: diskIndex)
      updateStatisticsForRemove(removedItem)
    }

    // Remove from displayed items
    items.removeAll { $0.id == id }

    // Update hasMoreItems
    hasMoreItems = items.count < allItemsOnDisk.count

    await persist(items: allItemsOnDisk)
  }

  func removeAll() async {
    allItemsOnDisk = []
    items = []
    hasMoreItems = false
    cachedStatistics = calculateStatistics(for: [])
    statistics = cachedStatistics!
    await persist(items: [])
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

  private func persist(items: [HistoryItem]) async {
    do {
      let data = try encoder.encode(items)
      try data.write(to: storageURL, options: [.atomic])
    } catch {
      log.error("Failed to persist history: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func calculateStatistics(for items: [HistoryItem]) -> HistoryStatistics {
    guard !items.isEmpty else {
      return .init(
        totalSessions: 0, cumulativeRecordingDuration: 0, totalSpend: 0, averageSessionLength: 0,
        sessionsWithErrors: 0)
    }

    let totalDuration = items.reduce(0) { $0 + $1.recordingDuration }
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
