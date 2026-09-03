import Combine
import SpeakCore
import SwiftUI

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
struct DashboardView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var history: HistoryManager
  @Environment(\.appVisualDensity) private var density
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var requestingPermission: PermissionType?
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
        heroHeader
        dashboardSections
      }
      .padding(density.pagePadding)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.brandAccent.opacity(0.06), Color(nsColor: .windowBackgroundColor)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    )
  }

  @ViewBuilder
  private var heroHeader: some View {
    if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
      compactHeroHeader
    } else {
      normalHeroHeader
    }
  }

  private var compactHeroHeader: some View {
    let stats = history.statistics
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: density.inlineSpacing) {
        Label("Dashboard", systemImage: "sparkles.rectangle.stack")
          .font(.subheadline.bold())
          .lineLimit(1)

        Spacer(minLength: 4)

        compactHeroMetric(
          value: "\(stats.totalSessions)",
          systemImage: "record.circle",
          accessibilityLabel: "Sessions"
        )
        compactHeroMetric(
          value: formattedDuration(stats.cumulativeRecordingDuration),
          systemImage: "timer",
          accessibilityLabel: "Recording time"
        )
        compactHeroMetric(
          value: formattedCurrency(stats.totalSpend),
          systemImage: "creditcard",
          accessibilityLabel: "Spend"
        )

        Button(action: environment.main.toggleRecordingFromUI) {
          compactRecordButtonLabel
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(environment.main.state == .recording ? .red : .accentColor)
        .disabled(isBusy)
        .keyboardShortcut(.space, modifiers: [.command])
        .accessibilityLabel(recordButtonAccessibility.label)
        .accessibilityHint(recordButtonAccessibility.hint)
        .accessibilityAddTraits(recordButtonAccessibility.traits)
      }

      if let preview = livePreviewText, !preview.isEmpty {
        Label(preview, systemImage: "waveform")
          .font(.caption.monospaced())
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }
    }
    .padding(density.cardPadding)
    .foregroundStyle(.white)
    .background(
      LinearGradient(
        colors: [Color.brandAccentDeep, Color.brandAccentWarm.opacity(0.9)],
        startPoint: .leading,
        endPoint: .trailing
      ),
      in: RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
    )
  }

  private var normalHeroHeader: some View {
    let stats = history.statistics
    return VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Speak Dashboard")
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
          Text(
            "Ready to capture ideas instantly. Check permissions, monitor usage, and dive into your latest sessions."
          )
          .font(.headline)
          .foregroundStyle(.white.opacity(0.85))
        }
        Spacer()
        Button(action: environment.main.toggleRecordingFromUI) {
          recordButtonLabel
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .background(
              Capsule()
                .fill(recordButtonBackground)
            )
            .overlay(
              Capsule()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .keyboardShortcut(.space, modifiers: [.command])
        .disabled(isBusy)
        .speakTooltip("Start a new recording instantly or stop the current one—Speak keeps you informed every step of the way.")
        .accessibilityLabel(recordButtonAccessibility.label)
        .accessibilityHint(recordButtonAccessibility.hint)
        .accessibilityAddTraits(recordButtonAccessibility.traits)
        .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 12)
        .animation(.easeInOut(duration: 0.2), value: environment.main.state)
      }

      if let preview = livePreviewText, !preview.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Live preview")
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.7))
          Text(preview)
            .font(.body.monospaced())
            .foregroundStyle(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.12))
        )
      }

      HStack(spacing: 16) {
        heroChip(title: "Sessions", value: "\(stats.totalSessions)", systemImage: "record.circle")
        heroChip(
          title: "Recording Time",
          value: formattedDuration(stats.cumulativeRecordingDuration),
          systemImage: "timer"
        )
        heroChip(
          title: "Spend",
          value: formattedCurrency(stats.totalSpend),
          systemImage: "creditcard"
        )
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.brandAccentDeep, Color.brandAccentWarm.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: Color.brandAccent.opacity(0.35), radius: 24, x: 0, y: 16)
  }

  private func compactHeroMetric(
    value: String,
    systemImage: String,
    accessibilityLabel: String
  ) -> some View {
    Label(value, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("\(accessibilityLabel): \(value)")
  }

  @ViewBuilder
  private var compactRecordButtonLabel: some View {
    switch environment.main.state {
    case .processing, .delivering:
      ProgressView()
        .controlSize(.mini)
    default:
      Image(systemName: buttonIcon)
    }
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
        ttsUsageChartSection
        ttsProviderChartSection
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

  private func heroChip(title: String, value: String, systemImage: String) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: systemImage)
        .imageScale(.large)
        .foregroundStyle(.white.opacity(0.85))
      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(value)
          .font(.title3.bold())
          .foregroundStyle(.white)
      }
      Spacer()
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.12))
    )
  }

  private var livePreviewText: String? {
    guard case .recording = environment.main.state else { return nil }
    return environment.main.livePreview
  }

  private var buttonTitle: String {
    switch environment.main.state {
    case .idle, .completed(_), .failed(_):
      return "Start Recording"
    case .recording:
      return "Recording…"
    case .processing:
      return "Transcribing…"
    case .delivering:
      return "Delivering…"
    }
  }

  private var buttonIcon: String {
    switch environment.main.state {
    case .idle, .completed(_), .failed(_):
      return "mic.fill"
    case .recording:
      return "record.circle.fill"
    case .processing:
      return "hourglass"
    case .delivering:
      return "arrowshape.turn.up.right"
    }
  }

  private var recordButtonAccessibility: RecordingControlAccessibility {
    RecordingControlAccessibility(state: environment.main.state)
  }

  @ViewBuilder
  private var recordButtonLabel: some View {
    switch environment.main.state {
    case .processing, .delivering:
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        Text(buttonTitle)
          .font(.headline)
      }
    case .recording:
      HStack(spacing: 12) {
        Image(systemName: buttonIcon)
          .font(.headline)
        Text(buttonTitle)
          .font(.headline)
      }
    default:
      HStack(spacing: 12) {
        Image(systemName: buttonIcon)
          .font(.headline)
        Text(buttonTitle)
          .font(.headline)
      }
    }
  }

  private var recordButtonBackground: LinearGradient {
    switch environment.main.state {
    case .recording:
      return LinearGradient(
        colors: [.red, Color.red.opacity(0.75)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    case .processing, .delivering:
      return LinearGradient(
        colors: [Color.gray.opacity(0.8), Color.gray.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    default:
      return LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private var isBusy: Bool {
    switch environment.main.state {
    case .processing, .delivering:
      return true
    default:
      return false
    }
  }

  private var permissionsSection: some View {
    DashboardCard(title: "Permissions", systemImage: "lock.shield", tint: Color.brandAccentWarm) {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: density.groupSpacing),
          count: 2
        ),
        spacing: density.groupSpacing
      ) {
        ForEach(PermissionType.availablePermissions(for: DistributionChannel.current)) { permission in
          permissionCard(for: permission)
        }
      }
    }
    .speakTooltip("Review and grant the permissions Speak needs so recordings and shortcuts work reliably.")
  }

  private func permissionCard(for permission: PermissionType) -> some View {
    let status = environment.permissions.status(for: permission)
    return Group {
      if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
        compactPermissionCard(for: permission, status: status)
      } else {
        regularPermissionCard(for: permission, status: status)
      }
    }
    .speakTooltip(permission.guidanceText)
  }

  private func compactPermissionCard(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    HStack(spacing: density.inlineSpacing) {
      Image(systemName: permission.systemIconName)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 0) {
        Text(permission.displayName)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(statusDescription(status))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 2)
      Circle()
        .fill(statusColor(status))
        .frame(width: 7, height: 7)
      compactPermissionAction(for: permission, status: status)
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(statusColor(status).opacity(0.35), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func compactPermissionAction(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    if environment.permissions.requestIssue(for: permission) != nil {
      Link(destination: permission.settingsURL) {
        Label("Open Settings", systemImage: "gear")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
    } else {
      Button {
        requestingPermission = permission
        Task { await request(permission) }
      } label: {
        Label(
          status.isGranted ? "Check" : "Request",
          systemImage: status.isGranted ? "arrow.clockwise" : "plus.circle"
        )
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
    }
  }

  private func regularPermissionCard(
    for permission: PermissionType,
    status: PermissionStatus
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: permission.systemIconName)
          .imageScale(.large)
        Text(permission.displayName)
          .font(.headline)
        Spacer()
        Circle()
          .fill(statusColor(status))
          .frame(width: 12, height: 12)
      }
      Text(statusDescription(status))
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let issue = environment.permissions.requestIssue(for: permission) {
        Text(issue.guidance(for: permission))
          .font(.caption)
          .foregroundStyle(.orange)
        Link("Open Settings", destination: permission.settingsURL)
          .buttonStyle(.bordered)
          .controlSize(.small)
      } else {
        Button(status.isGranted ? "Check" : "Request") {
          requestingPermission = permission
          Task { await request(permission) }
        }
        .controlSize(.small)
        .speakTooltip(permission.guidanceText)
      }
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(statusColor(status).opacity(0.4), lineWidth: 1)
    )
  }

  private func request(_ permission: PermissionType) async {
    _ = await environment.permissions.request(permission)
    await MainActor.run {
      requestingPermission = nil
    }
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted:
      return .green
    case .denied:
      return .red
    case .restricted:
      return .orange
    case .notDetermined:
      return .yellow
    }
  }

  private func statusDescription(_ status: PermissionStatus) -> String {
    switch status {
    case .granted:
      return "Granted"
    case .denied:
      return "Denied"
    case .restricted:
      return "Restricted"
    case .notDetermined:
      return "Not requested"
    }
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
          value: formattedDuration(stats.cumulativeRecordingDuration)
        )
        statCard(title: "Average Length", value: formattedDuration(stats.averageSessionLength))
        statCard(title: "Spend", value: formattedCurrency(stats.totalSpend))
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

  private func formattedDuration(_ duration: TimeInterval) -> String {
    guard duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }

  private func formattedCurrency(_ value: Decimal) -> String {
    guard value > 0 else { return "—" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
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
        Text(formattedDuration(item.recordingDuration))
      }
      .font(density.isCompact ? .caption.weight(.semibold) : .headline)

      if let postProcessed = item.postProcessedTranscription ?? item.rawTranscription {
        Text(postProcessed)
          .lineLimit(density.isCompact ? 2 : 4)
          .font(density.isCompact ? .caption : .body)
      }

      HStack {
        Label("Models: \(formattedModels(item.modelsUsed))", systemImage: "macpro.gen1")
        Spacer()
        if let cost = item.cost {
          Text(formattedCurrency(cost.total))
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

  private var ttsUsageChartSection: some View {
    DashboardCard(title: "Voice Output Usage", systemImage: "speaker.wave.3", tint: Color.brandLagoonDeep) {
      VStack(alignment: .leading, spacing: density.inlineSpacing) {
        let totalCharacters = environment.tts.totalCharactersThisMonth()
        let totalCost = environment.tts.totalCostThisMonth()

        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Characters This Month")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
            Text("\(totalCharacters)")
              .font(density.isCompact ? .caption.bold() : .title2.bold())
              .foregroundStyle(Color.brandLagoonDeep)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("Total Cost")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
            Text("$\(totalCost, format: .number.precision(.fractionLength(2)))")
              .font(density.isCompact ? .caption.bold() : .title2.bold())
              .foregroundStyle(Color.brandLagoonDeep)
          }
        }

        if totalCharacters > 0, !density.isCompact {
          Text(
            "\(totalCharacters) characters synthesized this month"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else if !density.isCompact {
          Text("No voice output generated yet this month")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Track your text-to-speech usage and costs this month.")
  }

  private var ttsProviderChartSection: some View {
    DashboardCard(title: "TTS Providers", systemImage: "waveform.circle", tint: Color.brandAccent) {
      let now = Date()
      let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!
      let usage = environment.tts.usageByProvider(since: monthAgo)

      if usage.isEmpty {
        VStack(spacing: density.inlineSpacing) {
          Image(systemName: "speaker.wave.2.circle")
            .font(density.isCompact ? .title3 : .largeTitle)
            .foregroundStyle(.secondary)
          Text("No TTS usage yet")
            .font(density.isCompact ? .caption : .subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: density.isCompact ? 44 : 120)
      } else {
        VStack(alignment: .leading, spacing: density.inlineSpacing) {
          ForEach(usage.sorted(by: { $0.value > $1.value }), id: \.key) { provider, count in
            HStack {
              Circle()
                .fill(providerColor(provider))
                .frame(width: density.isCompact ? 7 : 12, height: density.isCompact ? 7 : 12)
              Text(provider.displayName)
                .font(density.isCompact ? .caption : .subheadline)
              Spacer()
              Text("\(count) chars")
                .font(density.isCompact ? .caption2.monospacedDigit() : .subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .speakTooltip("See which TTS providers you use most frequently.")
  }

  private func providerColor(_ provider: TTSProvider) -> Color {
    switch provider {
    case .elevenlabs: return .brandAccent
    case .openai: return .green
    case .azure: return .brandLagoonDeep
    case .deepgram: return .brandAccentWarm
    case .soniox: return .brandLagoon
    case .cartesia: return .purple
    case .system: return .gray
    }
  }
}

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

private func formattedModels(_ identifiers: [String]) -> String {
  identifiers
    .map { ModelCatalog.friendlyName(for: $0) }
    .joined(separator: ", ")
}

private struct DashboardCard<Content: View>: View {
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

// @Implement: This file shows the default and most important currently configured setup. Initially it should show a disabled record button until minimum required permissions are enabled. IF and when they are provided the button should show "record". It should expose what permissions are currently granted and enable the user to grant those permissions if required.

// It should show when it's recording and the previously transcribed/processed item, it should also show the total number of recordings and the total spend and any other useful information. Ideally, we can make this into a nice graph. This should be kind of the friendly dashboard that we land on that gives you the key information for the app and can get you started.
