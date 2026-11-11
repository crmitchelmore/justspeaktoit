import Foundation

struct HistoryStatistics: Equatable {
  let totalSessions: Int
  let cumulativeRecordingDuration: TimeInterval
  let totalSpend: Decimal
  let averageSessionLength: TimeInterval
  let sessionsWithErrors: Int

  static let empty = HistoryStatistics(
    totalSessions: 0, cumulativeRecordingDuration: 0, totalSpend: 0, averageSessionLength: 0,
    sessionsWithErrors: 0)

  /// Duration counted towards statistics for a single item, falling back to
  /// the recording phase timestamps when no explicit duration was captured.
  static func effectiveDuration(of item: HistoryItem) -> TimeInterval {
    if item.recordingDuration > 0 {
      return item.recordingDuration
    }
    if let start = item.phaseTimestamps.recordingStarted, let end = item.phaseTimestamps.recordingEnded {
      return max(0, end.timeIntervalSince(start))
    }
    return 0
  }

  static func calculate(for items: [HistoryItem]) -> HistoryStatistics {
    guard !items.isEmpty else { return .empty }

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

  // MARK: - Incremental updates

  func appending(_ item: HistoryItem) -> HistoryStatistics {
    let newTotalSessions = totalSessions + 1
    let newCumulativeDuration = cumulativeRecordingDuration + Self.effectiveDuration(of: item)
    let newTotalSpend = totalSpend + (item.cost?.total ?? 0)
    let newErrorCount = sessionsWithErrors + (item.errors.isEmpty ? 0 : 1)
    let newAverageLength = newTotalSessions > 0 ? newCumulativeDuration / Double(newTotalSessions) : 0

    return HistoryStatistics(
      totalSessions: newTotalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
  }

  func removing(_ item: HistoryItem) -> HistoryStatistics {
    let newTotalSessions = max(0, totalSessions - 1)
    // Reset exactly to the empty baseline so float drift can't accumulate.
    guard newTotalSessions > 0 else { return .empty }
    let newCumulativeDuration = max(0, cumulativeRecordingDuration - Self.effectiveDuration(of: item))
    let newTotalSpend = max(0, totalSpend - (item.cost?.total ?? 0))
    let newErrorCount = max(0, sessionsWithErrors - (item.errors.isEmpty ? 0 : 1))
    let newAverageLength = newCumulativeDuration / Double(newTotalSessions)

    return HistoryStatistics(
      totalSessions: newTotalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
  }

  func replacing(_ oldItem: HistoryItem, with newItem: HistoryItem) -> HistoryStatistics {
    let durationDelta = Self.effectiveDuration(of: newItem) - Self.effectiveDuration(of: oldItem)
    let costDelta = (newItem.cost?.total ?? 0) - (oldItem.cost?.total ?? 0)
    let errorDelta = (newItem.errors.isEmpty ? 0 : 1) - (oldItem.errors.isEmpty ? 0 : 1)

    let newCumulativeDuration = max(0, cumulativeRecordingDuration + durationDelta)
    let newTotalSpend = max(0, totalSpend + costDelta)
    let newErrorCount = max(0, sessionsWithErrors + errorDelta)
    let newAverageLength = totalSessions > 0 ? newCumulativeDuration / Double(totalSessions) : 0

    return HistoryStatistics(
      totalSessions: totalSessions,
      cumulativeRecordingDuration: newCumulativeDuration,
      totalSpend: newTotalSpend,
      averageSessionLength: newAverageLength,
      sessionsWithErrors: newErrorCount
    )
  }
}
