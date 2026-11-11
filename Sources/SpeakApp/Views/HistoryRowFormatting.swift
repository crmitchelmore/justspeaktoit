import SpeakCore
import Foundation

/// Number and header formatting shared by the History row and its sections.
enum HistoryRowFormatting {
  static func formatDuration(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let totalHundredths = max(0, Int((duration * 100).rounded()))
    let minutes = totalHundredths / 6000
    let seconds = (totalHundredths / 100) % 60
    let hundredths = totalHundredths % 100
    if minutes > 0 {
      return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    } else {
      return String(format: "%02d.%02d", seconds, hundredths)
    }
  }

  static func formatCurrency(_ value: Decimal, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.isEmpty ? "USD" : currency
    return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
  }

  static func formattedHeaders(_ headers: [String: String]) -> String {
    headers
      .sorted { $0.key < $1.key }
      .map { "\($0): \($1)" }
      .joined(separator: "\n")
  }
}

/// The models one pipeline phase used, as the History row lists them.
struct HistoryModelsByPhase {
  let phase: ModelUsagePhase
  let phaseLabel: String
  let models: String
}

extension HistoryItem {
  /// Model usages grouped by phase in pipeline order, with friendly names.
  var modelsByPhase: [HistoryModelsByPhase] {
    guard !modelUsages.isEmpty else { return [] }

    let groups = Dictionary(grouping: modelUsages, by: { $0.phase })
      .sorted { $0.key.historyOrder < $1.key.historyOrder }

    return groups.map { phase, usages in
      let models = usages.map { ModelCatalog.friendlyName(for: $0.modelIdentifier) }.joined(separator: ", ")
      return HistoryModelsByPhase(phase: phase, phaseLabel: phase.historyLabel, models: models)
    }
  }

  /// One line such as "Live: Nova-3 • Post-processing: GPT-5 mini", or nil.
  var modelsSummaryByPhase: String? {
    guard !modelUsages.isEmpty else { return nil }
    return modelsByPhase.map { "\($0.phaseLabel): \($0.models)" }.joined(separator: " • ")
  }
}

extension ModelUsagePhase {
  var historyLabel: String {
    switch self {
    case .transcriptionLive:
      return "Live"
    case .transcriptionBatch:
      return "Batch"
    case .transcriptionLocal:
      return "Local"
    case .postProcessing:
      return "Post-processing"
    }
  }

  var historyOrder: Int {
    switch self {
    case .transcriptionLive:
      return 0
    case .transcriptionBatch:
      return 1
    case .transcriptionLocal:
      // Distinct from .transcriptionBatch: equal ranks leave the sort order of
      // the two phases unspecified, so the grouped summary could reorder itself
      // between renders.
      return 2
    case .postProcessing:
      return 3
    }
  }
}
