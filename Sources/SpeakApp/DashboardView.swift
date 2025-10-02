import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var requestingPermission: PermissionType?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        heroHeader
        dashboardSections
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.cyan.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    )
  }

  private var heroHeader: some View {
    let stats = environment.history.statistics
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
        colors: [Color.cyan, Color.blue.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: Color.cyan.opacity(0.35), radius: 24, x: 0, y: 16)
  }

  private var dashboardSections: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
      permissionsSection
      statisticsSection
      recentSection
    }
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
    DashboardCard(title: "Permissions", systemImage: "lock.shield", tint: Color.pink) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 16
      ) {
        ForEach(PermissionType.allCases) { permission in
          permissionCard(for: permission)
        }
      }
    }
  }

  private func permissionCard(for permission: PermissionType) -> some View {
    let status = environment.permissions.status(for: permission)
    return VStack(alignment: .leading, spacing: 8) {
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

      Button(status.isGranted ? "Check" : "Request") {
        requestingPermission = permission
        Task { await request(permission) }
      }
      .controlSize(.small)
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
    let stats = environment.history.statistics
    return DashboardCard(title: "Insights", systemImage: "chart.xyaxis.line", tint: Color.indigo) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
        statCard(title: "Sessions", value: "\(stats.totalSessions)")
        statCard(
          title: "Recording Time",
          value: formattedDuration(stats.cumulativeRecordingDuration)
        )
        statCard(title: "Average Length", value: formattedDuration(stats.averageSessionLength))
        statCard(title: "Spend", value: formattedCurrency(stats.totalSpend))
      }
    }
  }

  private func statCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.bold())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
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
    DashboardCard(title: "Recent Session", systemImage: "clock.arrow.circlepath", tint: Color.cyan)
    {
      if let item = environment.history.items.first {
        recentItemView(item)
      } else {
        Text("No recordings yet. Press Record to begin.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func recentItemView(_ item: HistoryItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(item.createdAt, style: .date)
        Text(item.createdAt, style: .time)
          .foregroundStyle(.secondary)
        Spacer()
        Text(formattedDuration(item.recordingDuration))
      }
      .font(.headline)

      if let postProcessed = item.postProcessedTranscription ?? item.rawTranscription {
        Text(postProcessed)
          .lineLimit(4)
          .font(.body)
      }

      HStack {
        Label("Models: \(formattedModels(item.modelsUsed))", systemImage: "macpro.gen1")
        Spacer()
        if let cost = item.cost {
          Text(formattedCurrency(cost.total))
            .font(.subheadline)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(.thinMaterial)
    )
  }
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
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: 44, height: 44)
          Image(systemName: systemImage)
            .foregroundStyle(tint)
            .font(.system(size: 20, weight: .semibold))
        }
        Text(title)
          .font(.headline)
        Spacer(minLength: 0)
      }

      content
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(tint.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 12)
  }
}

// @Implement: This file shows the default and most important currently configured setup. Initially it should show a disabled record button until minimum required permissions are enabled. IF and when they are provided the button should show "record". It should expose what permissions are currently granted and enable the user to grant those permissions if required.

// It should show when it's recording and the previously transcribed/processed item, it should also show the total number of recordings and the total spend and any other useful information. Ideally, we can make this into a nice graph. This should be kind of the friendly dashboard that we land on that gives you the key information for the app and can get you started.
