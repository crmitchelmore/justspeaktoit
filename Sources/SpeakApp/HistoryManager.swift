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

  private let storageURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let log = Logger(subsystem: "com.github.speakapp", category: "HistoryManager")

  init(fileManager: FileManager = .default) {
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
          self.items = []
          self.statistics = self.calculateStatistics(for: [])
        }
        return
      }
      let data = try Data(contentsOf: storageURL)
      let decoded = try decoder.decode([HistoryItem].self, from: data)
      await MainActor.run {
        self.items = decoded.sorted { $0.createdAt > $1.createdAt }
        self.statistics = self.calculateStatistics(for: decoded)
      }
    } catch {
      log.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
    }
  }

  func append(_ item: HistoryItem) async {
    var current = items
    current.insert(item, at: 0)
    items = current
    statistics = calculateStatistics(for: current)
    await persist(items: current)
  }

  func update(_ item: HistoryItem) async {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    var updated = items
    updated[index] = item
    items = updated.sorted { $0.createdAt > $1.createdAt }
    statistics = calculateStatistics(for: updated)
    await persist(items: updated)
  }

  func remove(id: UUID) async {
    let updated = items.filter { $0.id != id }
    items = updated
    statistics = calculateStatistics(for: updated)
    await persist(items: updated)
  }

  func removeAll() async {
    items = []
    statistics = calculateStatistics(for: [])
    await persist(items: [])
  }

  func items(matching filter: HistoryFilter) -> [HistoryItem] {
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
}
