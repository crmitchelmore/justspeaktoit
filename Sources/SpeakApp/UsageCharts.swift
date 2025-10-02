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
  func dailyUsageForLastMonth() -> [DailyUsageData] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
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
      // Determine which model was used for this phase
      let model = item.modelForPhase(phase)
      guard let model = model else { continue }

      let current = modelData[model] ?? (count: 0, spend: Decimal(0))
      let spend = item.spendForPhase(phase) ?? Decimal(0)
      modelData[model] = (count: current.count + 1, spend: current.spend + spend)
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
        !model.contains("gpt") && !model.contains("claude") && !model.contains("llama")
      } ?? modelsUsed.first
    case .postProcessing:
      // Look for chat/LLM models
      return modelsUsed.first { model in
        model.contains("gpt") || model.contains("claude") || model.contains("llama")
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
  let data: [DailyUsageData]
  @State private var showDuration = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(showDuration ? "Recording Time per Day" : "Recordings per Day")
          .font(.headline)
        Spacer()
        Toggle(showDuration ? "Duration" : "Count", isOn: $showDuration)
          .toggleStyle(.switch)
          .controlSize(.small)
      }

      if data.isEmpty {
        Text("No data for the last 30 days")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(height: 200)
          .frame(maxWidth: .infinity)
      } else {
        Chart(data) { item in
          BarMark(
            x: .value("Date", item.date, unit: .day),
            y: .value(showDuration ? "Duration" : "Count", showDuration ? item.totalDuration / 60 : Double(item.count))
          )
          .foregroundStyle(Color.cyan.gradient)
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
        .frame(height: 200)
      }

      if !data.isEmpty {
        Text(showDuration ? "Minutes per day" : "Number of recordings per day")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct ModelUsageChart: View {
  let title: String
  let data: [ModelUsageData]
  let color: Color
  @State private var showSpend = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Toggle(showSpend ? "Spend" : "Count", isOn: $showSpend)
          .toggleStyle(.switch)
          .controlSize(.small)
      }

      if data.isEmpty {
        Text("No usage data available")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(height: 200)
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
        .frame(height: max(200, CGFloat(data.count * 40)))
      }

      if !data.isEmpty {
        Text(showSpend ? "Total spend by model (USD)" : "Number of uses per model")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
