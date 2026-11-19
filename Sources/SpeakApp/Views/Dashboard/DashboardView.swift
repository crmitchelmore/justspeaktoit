import Combine
import SpeakCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var history: HistoryManager
  @Environment(\.appVisualDensity) private var density
  @StateObject private var speechInsights = SpeechInsightsModel()

  /// Chart inputs derived from the *whole* history. Cached in state and
  /// refreshed on `history.contentRevision` (same reasoning as the speech
  /// insights below) so that unrelated `HistoryManager` publishes — paging
  /// flipping `isLoadingMore`, a persistence error, a load-state change — do
  /// not re-walk every record on the main actor while the body evaluates.
  @State private var aggregates = DashboardAggregates(items: [])
  /// The day the cached `aggregates` were built for. The daily-usage series is
  /// a rolling 30-day window ending "today", so a dashboard left open across
  /// midnight has to rebuild even when history has not changed (issue: stale
  /// axis after a day rollover). Refreshed from `NSCalendarDayChanged`.
  @State private var aggregatesDay = Calendar.current.startOfDay(for: .now)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: density.sectionSpacing) {
        DashboardHeroHeader()
        dashboardSections
      }
      .padding(density.pagePadding)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .pageBackground(.dashboard)
  }

  private var dashboardSections: some View {
    VStack(spacing: density.sectionSpacing) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: density.sectionSpacing)],
        spacing: density.sectionSpacing
      ) {
        permissionsSection
        statisticsSection
        recentSection
      }

      // Speech analytics (computed locally from raw transcripts)
      speechInsightsSection

      // Usage Charts
      dailyUsageChartSection

      latencySection

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: density.sectionSpacing)],
        spacing: density.sectionSpacing
      ) {
        transcriptionModelChartSection
        postProcessingModelChartSection
      }

      // TTS Charts
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: density.sectionSpacing)],
        spacing: density.sectionSpacing
      ) {
        DashboardVoiceOutputUsageCard()
        DashboardTTSProvidersCard()
      }
    }
    // One pass over history per content revision *and* per day feeds all five
    // charts. `contentRevision` is bumped by every mutator that touches
    // `allItems` (load, append, update, remove, remove-all — CloudKit merges
    // included), and paging only ever appends to the already-counted `items`
    // page; the day is the other input, because `dailyUsageForLastMonth`
    // derives its window from it.
    .task(id: aggregatesKey) {
      aggregates = DashboardAggregates(items: history.allItems, referenceDate: aggregatesDay)
    }
    // Posted on a background thread at midnight and on wake, so hop to main
    // before touching view state.
    .onReceive(
      NotificationCenter.default
        .publisher(for: .NSCalendarDayChanged)
        .receive(on: DispatchQueue.main)
    ) { _ in
      let today = Calendar.current.startOfDay(for: .now)
      if today != aggregatesDay {
        aggregatesDay = today
      }
    }
  }

  private var aggregatesKey: DashboardAggregatesKey {
    DashboardAggregatesKey(revision: history.contentRevision, startOfDay: aggregatesDay)
  }

  private var permissionsSection: some View {
    DashboardPermissionsSection(permissions: environment.permissions)
  }

  private var statisticsSection: some View {
    let stats = history.statistics
    return DashboardCard(title: "Insights", systemImage: "chart.xyaxis.line", tint: Color.brandAccentDeep) {
      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(minimum: density.isCompact ? 92 : 160),
            spacing: density.groupSpacing
          )
        ],
        spacing: density.groupSpacing
      ) {
        statCard(title: "Sessions", value: "\(stats.totalSessions)")
        statCard(
          title: "Recording Time",
          value: DashboardFormat.duration(stats.cumulativeRecordingDuration)
        )
        statCard(title: "Average Length", value: DashboardFormat.duration(stats.averageSessionLength))
        statCard(title: "Spend", value: DashboardFormat.currency(stats.totalSpend))
      }
    }
    .speakTooltip("Keep tabs on how often you record, how long sessions run, and what they cost over time.")
  }

  private func statCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 1 : 6) {
      Text(title)
        .font(density.isCompact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(density.isCompact ? .caption.bold() : .title3.bold())
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(density.isCompact ? 5 : 16)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 7 : 20, style: .continuous)
        .fill(Color.accentColor.opacity(0.08))
    )
  }

  private var recentSection: some View {
    DashboardCard(title: "Recent Session", systemImage: "clock.arrow.circlepath", tint: Color.brandLagoon) {
      if let item = history.items.first {
        recentItemView(item)
      } else {
        Text("No recordings yet. Press Record to begin.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .speakTooltip("Revisit your latest session with transcripts, timing, and model details all in one place.")
  }

  private func recentItemView(_ item: HistoryItem) -> some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 3 : 8) {
      HStack {
        Text(item.createdAt, style: .date)
        Text(item.createdAt, style: .time)
          .foregroundStyle(.secondary)
        Spacer()
        Text(DashboardFormat.duration(item.recordingDuration))
      }
      .font(density.isCompact ? .caption.weight(.semibold) : .headline)

      if let postProcessed = item.postProcessedTranscription ?? item.rawTranscription {
        Text(postProcessed)
          .lineLimit(density.isCompact ? 2 : 4)
          .font(density.isCompact ? .caption : .body)
      }

      HStack {
        Label("Models: \(DashboardFormat.models(item.modelsUsed))", systemImage: "macpro.gen1")
        Spacer()
        if let cost = item.cost {
          Text(DashboardFormat.currency(cost.total))
            .font(.subheadline)
        }
      }
      .font(density.isCompact ? .caption2 : .subheadline)
      .foregroundStyle(.secondary)
    }
    .padding(density.isCompact ? 5 : 16)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 7 : 20, style: .continuous)
        .fill(.thinMaterial)
    )
  }

  private var speechInsightsSection: some View {
    SpeechInsightsSection(model: speechInsights)
      // Keyed on the history content revision, not `statistics`: statistics
      // ignore transcript text, so an in-place edit (CloudKit merge, local
      // reprocess) would otherwise leave the insights stale.
      .task(id: history.contentRevision) {
        speechInsights.refresh(using: history.allItems)
      }
  }

  private var dailyUsageChartSection: some View {
    DashboardCard(title: "Daily Usage", systemImage: "chart.bar.fill", tint: Color.brandLagoon) {
      DailyRecordingsChart(data: aggregates.dailyUsage)
    }
    .speakTooltip("See when you rely on Speak the most so you can plan deep work and reviews thoughtfully.")
  }

  private var latencySection: some View {
    DashboardCard(title: "Latency", systemImage: "bolt.badge.clock", tint: Color.brandLagoonDeep) {
      LatencyInsightsView(
        providers: aggregates.latencyProviders,
        overview: aggregates.latencyOverview
      )
    }
    .speakTooltip(
      "How fast dictation feels: cold start, time to first words, and stop-to-inserted latency per provider (p50/p95)."
    )
  }

  private var transcriptionModelChartSection: some View {
    DashboardCard(title: "Transcription Models", systemImage: "waveform", tint: Color.green) {
      ModelUsageChart(
        title: "Transcription Model Usage",
        data: aggregates.transcriptionModels,
        color: .green
      )
    }
    .speakTooltip("Compare which transcription services you lean on most and balance accuracy with cost.")
  }

  private var postProcessingModelChartSection: some View {
    DashboardCard(title: "Post-Processing Models", systemImage: "wand.and.stars", tint: Color.brandAccent) {
      ModelUsageChart(
        title: "Post-Processing Model Usage",
        data: aggregates.postProcessingModels,
        color: .brandAccent
      )
    }
    .speakTooltip("Understand which refinement models polish your transcripts after the first pass.")
  }
}

// @Implement: This file shows the default and most important currently configured setup. Initially it should show a
// disabled record button until minimum required permissions are enabled. IF and when they are provided the button
// should show "record". It should expose what permissions are currently granted and enable the user to grant those
// permissions if required.

// It should show when it's recording and the previously transcribed/processed item, it should also show the total
// number of recordings and the total spend and any other useful information. Ideally, we can make this into a nice
// graph. This should be kind of the friendly dashboard that we land on that gives you the key information for the app
// and can get you started.
