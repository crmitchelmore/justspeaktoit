import SpeakCore
import Charts
import SwiftUI

// MARK: - Data Models

struct DailyUsageData: Identifiable {
  let id = UUID()
  let date: Date
  let count: Int
  let totalDuration: TimeInterval
}

struct ModelUsageData: Identifiable {
  let id = UUID()
  let modelName: String
  let count: Int
  let spend: Decimal
}

// MARK: - Data Aggregation

extension Array where Element == HistoryItem {
  /// The rolling 30-day series ending on `referenceDate`'s day.
  ///
  /// The window is passed in rather than read from the clock so callers that
  /// cache the result (the dashboard does) can key that cache on the same day
  /// the series was built for — otherwise a window opened before midnight keeps
  /// rendering yesterday's axis. `Date.now` keeps the call sites unchanged.
  func dailyUsageForLastMonth(referenceDate: Date = .now) -> [DailyUsageData] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: referenceDate)
    let monthAgo = calendar.date(byAdding: .day, value: -30, to: today)!

    // Filter items from the last month
    let recentItems = self.filter { $0.createdAt >= monthAgo }

    // Group by day
    var dailyData: [Date: (count: Int, duration: TimeInterval)] = [:]
    for item in recentItems {
      let dayStart = calendar.startOfDay(for: item.createdAt)
      let current = dailyData[dayStart] ?? (count: 0, duration: 0)
      dailyData[dayStart] = (count: current.count + 1, duration: current.duration + item.recordingDuration)
    }

    // Create data points for all days in the range (including zeros)
    var results: [DailyUsageData] = []
    var currentDate = monthAgo
    while currentDate <= today {
      let data = dailyData[currentDate] ?? (count: 0, duration: 0)
      results.append(DailyUsageData(date: currentDate, count: data.count, totalDuration: data.duration))
      currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
    }

    return results.sorted { $0.date < $1.date }
  }

  func modelUsage(for phase: ModelPhase) -> [ModelUsageData] {
    var modelData: [String: (count: Int, spend: Decimal)] = [:]

    for item in self {
      // Use explicit phase tracking if available, otherwise fall back to inference
      if !item.modelUsages.isEmpty {
        let relevantUsages: [ModelUsage]
        switch phase {
        case .transcription:
          relevantUsages = item.modelUsages.filter {
            $0.phase == .transcriptionLive || $0.phase == .transcriptionBatch || $0.phase == .transcriptionLocal
          }
        case .postProcessing:
          relevantUsages = item.modelUsages.filter { $0.phase == .postProcessing }
        }

        for usage in relevantUsages {
          let current = modelData[usage.modelIdentifier] ?? (count: 0, spend: Decimal(0))
          let spend = item.spendForPhase(phase) ?? Decimal(0)
          modelData[usage.modelIdentifier] = (count: current.count + 1, spend: current.spend + spend)
        }
      } else {
        // Fallback for legacy items without phase tracking
        let model = item.modelForPhase(phase)
        guard let model = model else { continue }

        let current = modelData[model] ?? (count: 0, spend: Decimal(0))
        let spend = item.spendForPhase(phase) ?? Decimal(0)
        modelData[model] = (count: current.count + 1, spend: current.spend + spend)
      }
    }

    return modelData.map { key, value in
      ModelUsageData(modelName: ModelCatalog.friendlyName(for: key), count: value.count, spend: value.spend)
    }.sorted { $0.count > $1.count }
  }
}

enum ModelPhase {
  case transcription
  case postProcessing
}

extension HistoryItem {
  func modelForPhase(_ phase: ModelPhase) -> String? {
    // This is a simplified approach - we'll try to infer from model names
    // In a real scenario, you might want to track this explicitly
    switch phase {
    case .transcription:
      // Look for transcription models (non-chat models)
      return modelsUsed.first { model in
        !model.contains("gpt") && !model.contains("claude") && !model.contains("llama") && !model.contains("inception") && !model.contains("mercury")
      } ?? modelsUsed.first
    case .postProcessing:
      // Look for chat/LLM models
      return modelsUsed.first { model in
        model.contains("gpt") || model.contains("claude") || model.contains("llama") || model.contains("inception") || model.contains("mercury")
      }
    }
  }

  func spendForPhase(_ phase: ModelPhase) -> Decimal? {
    // Simplified - split cost equally if we can't determine
    guard let cost = cost?.total else { return nil }

    // If only one model, attribute all cost to it
    if modelsUsed.count == 1 {
      return cost
    }

    // Otherwise, estimate based on phase
    switch phase {
    case .transcription:
      // Transcription typically cheaper
      return cost * Decimal(0.3)
    case .postProcessing:
      // Post-processing typically more expensive
      return cost * Decimal(0.7)
    }
  }
}

// MARK: - Chart Views

struct DailyRecordingsChart: View {
  @Environment(\.appVisualDensity) private var density
  let data: [DailyUsageData]
  @State private var showDuration = false

  var body: some View {
    VStack(alignment: .leading, spacing: density.inlineSpacing) {
      HStack {
        if !density.isCompact {
          Text(showDuration ? "Recording Time per Day" : "Recordings per Day")
            .font(.headline)
        }
        Spacer()
        Toggle(showDuration ? "Duration" : "Count", isOn: $showDuration)
          .toggleStyle(.switch)
          .controlSize(.small)
          .modifier(
            CompactChartToggleModifier(
              isCompact: density.isCompact,
              accessibilityLabel: showDuration
                ? "Show recording duration"
                : "Show recording count"
            )
          )
      }

      if data.isEmpty {
        Text("No data for the last 30 days")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(height: density.chartHeight)
          .frame(maxWidth: .infinity)
      } else {
        Chart(data) { item in
          BarMark(
            x: .value("Date", item.date, unit: .day),
            y: .value(showDuration ? "Duration" : "Count", showDuration ? item.totalDuration / 60 : Double(item.count))
          )
          .foregroundStyle(Color.brandLagoon.gradient)
        }
        .chartYAxis {
          AxisMarks(position: .leading)
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .day, count: 5)) { value in
            if let date = value.as(Date.self) {
              AxisValueLabel {
                Text(date, format: .dateTime.month(.abbreviated).day())
                  .font(.caption2)
              }
            }
          }
        }
        .frame(height: density.chartHeight)
      }

      if !data.isEmpty, !density.isCompact {
        Text(showDuration ? "Minutes per day" : "Number of recordings per day")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct ModelUsageChart: View {
  @Environment(\.appVisualDensity) private var density
  let title: String
  let data: [ModelUsageData]
  let color: Color
  @State private var showSpend = false

  var body: some View {
    VStack(alignment: .leading, spacing: density.inlineSpacing) {
      HStack {
        if !density.isCompact {
          Text(title)
            .font(.headline)
        }
        Spacer()
        Toggle(showSpend ? "Spend" : "Count", isOn: $showSpend)
          .toggleStyle(.switch)
          .controlSize(.small)
          .modifier(
            CompactChartToggleModifier(
              isCompact: density.isCompact,
              accessibilityLabel: showSpend
                ? "Show model spend"
                : "Show model usage count"
            )
          )
      }

      if data.isEmpty {
        Text("No usage data available")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(height: density.chartHeight)
          .frame(maxWidth: .infinity)
      } else {
        Chart(data) { item in
          BarMark(
            x: .value(showSpend ? "Spend" : "Count", showSpend ? (item.spend as NSDecimalNumber).doubleValue : Double(item.count)),
            y: .value("Model", item.modelName)
          )
          .foregroundStyle(color.gradient)
        }
        .chartXAxis {
          AxisMarks(position: .bottom)
        }
        .frame(
          height: max(
            density.chartHeight,
            CGFloat(data.count * (density.isCompact ? 22 : 40))
          )
        )
      }

      if !data.isEmpty, !density.isCompact {
        Text(showSpend ? "Total spend by model (USD)" : "Number of uses per model")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct CompactChartToggleModifier: ViewModifier {
  let isCompact: Bool
  let accessibilityLabel: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if isCompact {
      content
        .labelsHidden()
        .accessibilityLabel(accessibilityLabel)
    } else {
      content
    }
  }
}
