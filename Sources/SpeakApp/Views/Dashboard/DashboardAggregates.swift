import Foundation
import SpeakCore
import SwiftUI

/// The five full-history aggregations the dashboard charts render, computed
/// together in one pass so the view body reads plain stored values.
///
/// Building it for an empty history is the same work the charts did on a cold
/// dashboard before, so the initial value is identical to what the first
/// refresh produces when there is nothing recorded yet.
struct DashboardAggregates {
  let dailyUsage: [DailyUsageData]
  let latencyProviders: [ProviderLatencyInsight]
  let latencyOverview: LatencyOverview
  let transcriptionModels: [ModelUsageData]
  let postProcessingModels: [ModelUsageData]

  init(items: [HistoryItem], referenceDate: Date = .now) {
    dailyUsage = items.dailyUsageForLastMonth(referenceDate: referenceDate)
    latencyProviders = items.latencyInsightsByProvider()
    latencyOverview = items.latencyOverview()
    transcriptionModels = items.modelUsage(for: .transcription)
    postProcessingModels = items.modelUsage(for: .postProcessing)
  }
}

/// What `DashboardAggregates` actually depends on: the history content *and*
/// the day the rolling 30-day usage window ends on. Keying the dashboard's
/// `.task` on both is what makes the charts survive a midnight rollover with
/// the window left open.
struct DashboardAggregatesKey: Equatable {
  let revision: UInt64
  let startOfDay: Date
}

/// Text formats shared by the hero header, insight tiles and recent-session card.
enum DashboardFormat {
  static func duration(_ duration: TimeInterval) -> String {
    guard duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }

  static func currency(_ value: Decimal) -> String {
    guard value > 0 else { return "—" }
    return HistoryDetailFormatting.formatCurrency(value, currency: "USD")
  }

  static func models(_ identifiers: [String]) -> String {
    identifiers
      .map { ModelCatalog.friendlyName(for: $0) }
      .joined(separator: ", ")
  }
}

struct DashboardCard<Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let content: Content

  init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    SpeakDensityCard(title: title, systemImage: systemImage, tint: tint) {
      content
    }
  }
}
