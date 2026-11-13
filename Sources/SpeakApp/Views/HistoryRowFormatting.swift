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
    HistoryDetailFormatting.formatCurrency(value, currency: currency)
  }

  static func formattedHeaders(_ headers: [String: String]) -> String {
    headers
      .sorted { $0.key < $1.key }
      .map { "\($0): \($1)" }
      .joined(separator: "\n")
  }
}

extension HistoryItem {
  /// Model usages grouped by phase in pipeline order, with friendly names.
  var modelsByPhase: [HistoryModelsByPhase] {
    HistoryDetailFormatting.modelsByPhase(modelUsages)
  }

  /// One line such as "Live: Nova-3 • Post-processing: GPT-5 mini", or nil.
  var modelsSummaryByPhase: String? {
    guard !modelUsages.isEmpty else { return nil }
    return modelsByPhase.map { "\($0.phaseLabel): \($0.models)" }.joined(separator: " • ")
  }
}
