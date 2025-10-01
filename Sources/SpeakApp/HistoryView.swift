import AVFoundation
import AppKit
import Combine
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var searchText: String = ""
  @State private var showErrorsOnly: Bool = false
  @State private var historyItems: [HistoryItem] = []
  @State private var historyStats: HistoryStatistics = .init(
    totalSessions: 0,
    cumulativeRecordingDuration: 0,
    totalSpend: 0,
    averageSessionLength: 0,
    sessionsWithErrors: 0
  )

  private var filteredItems: [HistoryItem] {
    var filter = HistoryFilter.none
    filter.searchText = searchText.isEmpty ? nil : searchText
    filter.includeErrorsOnly = showErrorsOnly
    return apply(filter: filter, to: historyItems)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header
          if filteredItems.isEmpty {
            emptyState
          } else {
            LazyVStack(spacing: 20) {
              ForEach(filteredItems) { item in
                HistoryListRow(item: item)
                  .id(item.id)
              }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: filteredItems)
          }
        }
        .padding(24)
        .frame(maxWidth: 1100, alignment: .center)
      }
      .onAppear {
        historyItems = environment.history.items
        historyStats = environment.history.statistics
      }
      .onReceive(environment.history.$items) { items in
        let previous = historyItems
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
          historyItems = items
        }
        guard let newest = items.first else { return }
        let wasPresent = previous.contains(where: { $0.id == newest.id })
        if !wasPresent {
          DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
              proxy.scrollTo(newest.id, anchor: .top)
            }
          }
        }
      }
      .onReceive(environment.history.$statistics) { stats in
        withAnimation(.easeInOut(duration: 0.2)) {
          historyStats = stats
        }
      }
    }
    .background(
      LinearGradient(
        colors: [.accentColor.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
  }

  private var header: some View {
    return VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Session History")
          .font(.largeTitle.bold())
          .foregroundStyle(.white)
        Text(
          "Search, filter, and replay past recordings with full network context and transcripts."
        )
        .font(.headline)
        .foregroundStyle(.white.opacity(0.85))
      }

      HStack(spacing: 16) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.white.opacity(0.7))
          TextField("Search history", text: $searchText)
            .textFieldStyle(.plain)
            .foregroundColor(.white)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.14))
        )

        Toggle("Errors only", isOn: $showErrorsOnly)
          .toggleStyle(.switch)
          .tint(.white)
          .foregroundStyle(.white)

        Spacer()

        Button {
          Task { await environment.history.removeAll() }
        } label: {
          Label("Clear All", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(Color.accentColor)
        .disabled(historyItems.isEmpty)
      }

      HStack(spacing: 16) {
        historyChip(title: "Sessions", value: "\(historyStats.totalSessions)")
        historyChip(title: "Errors", value: "\(historyStats.sessionsWithErrors)")
        historyChip(
          title: "Average Length",
          value: formattedDuration(historyStats.averageSessionLength)
        )
        historyChip(title: "Spend", value: formattedCurrency(historyStats.totalSpend))
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.accentColor.opacity(0.3), radius: 24, x: 0, y: 16)
  }

  private var emptyState: some View {
    VStack(spacing: 18) {
      Image(systemName: "waveform")
        .font(.system(size: 44, weight: .medium))
        .foregroundStyle(Color.accentColor)
      Text("No history yet")
        .font(.title2.bold())
      Text("Record a session to see transcripts, costs, and network activity appear here.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button(action: environment.main.toggleRecordingFromUI) {
        Label("Start a recording", systemImage: "mic.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(environment.main.isBusy)
    }
    .frame(maxWidth: .infinity)
    .padding(40)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
    )
  }

  private func historyChip(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
      Text(value)
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.15))
    )
  }

  private static let headerCurrencyFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter
  }()

  private func formattedDuration(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }

  private func formattedCurrency(_ value: Decimal) -> String {
    HistoryView.headerCurrencyFormatter.string(from: value as NSDecimalNumber) ?? "—"
  }

  private func apply(filter: HistoryFilter, to items: [HistoryItem]) -> [HistoryItem] {
    items.filter { item in
      if let text = filter.searchText?.lowercased(), !text.isEmpty {
        let combined = [item.rawTranscription, item.postProcessedTranscription]
          .compactMap { $0?.lowercased() }
          .joined(separator: "\n")
        if !combined.contains(text) {
          return false
        }
      }

      if !filter.modelIdentifiers.isEmpty {
        let itemModels = Set(item.modelsUsed.map { $0.lowercased() })
        let requested = filter.modelIdentifiers.map { $0.lowercased() }
        if Set(requested).intersection(itemModels).isEmpty {
          return false
        }
      }

      if filter.includeErrorsOnly && item.errors.isEmpty {
        return false
      }

      if let range = filter.dateRange, !range.contains(item.createdAt) {
        return false
      }

      return true
    }
  }
}

private struct HistoryListRow: View {
  @EnvironmentObject private var environment: AppEnvironment
  let item: HistoryItem
  @State private var isExpanded: Bool = false
  @State private var showNetworkDetails: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Button {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 16) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 8) {
                badgeViews
              }
              VStack(alignment: .leading, spacing: 8) {
                badgeViews
              }
            }
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
              .imageScale(.large)
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color.accentColor, Color.accentColor.opacity(0.3))
          }

          if let transcript = bestTranscript {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

              Button {
                copyToPasteboard(transcript)
              } label: {
                Label("Copy", systemImage: "doc.on.doc")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .help("Copy the best available transcript")
            }
          } else {
            Text(previewText)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          if let models = modelsSummary {
            Label(
              models.replacingOccurrences(of: "\n", with: ", "),
              systemImage: "brain.head.profile"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Divider()
          .padding(.vertical, 4)

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
              if !item.networkExchanges.isEmpty {
                networkSummaryButton
                if showNetworkDetails {
                  networkSection
                }
              }

              metaSection

              if let url = item.audioFileURL {
                AudioPlaybackControls(url: url)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 20) {
              transcriptSection

              if !item.errors.isEmpty {
                errorSection
              }

              footerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 20) {
            if !item.networkExchanges.isEmpty {
              networkSummaryButton
              if showNetworkDetails {
                networkSection
              }
            }

            metaSection

            if let url = item.audioFileURL {
              AudioPlaybackControls(url: url)
            }

            transcriptSection

            if !item.errors.isEmpty {
              errorSection
            }

            footerActions
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(24)
    .background(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(borderColor, lineWidth: 1)
    )
    .shadow(color: borderColor.opacity(0.3), radius: 18, x: 0, y: 12)
    .onChange(of: isExpanded) { _, expanded in
      if !expanded {
        showNetworkDetails = false
      }
    }
  }

  private var previewText: String {
    if let processed = processedTranscriptToDisplay {
      return processed
    }
    if let raw = item.rawTranscription, !raw.isEmpty {
      return raw
    }
    return item.trigger.hotKeyDescription
  }

  private var borderColor: Color {
    item.errors.isEmpty ? Color.accentColor.opacity(0.15) : Color.orange.opacity(0.35)
  }

  private var metaColumns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: 160, maximum: 340), spacing: 10, alignment: .topLeading
      )
    ]
  }

  private var formattedCreatedAt: String {
    item.createdAt.formatted(date: .abbreviated, time: .shortened)
  }

  @ViewBuilder
  private var badgeViews: some View {
    historyBadge(
      icon: "calendar",
      title: "Created",
      value: formattedCreatedAt
    )

    if item.recordingDuration > 0 {
      historyBadge(
        icon: "waveform",
        title: "Audio",
        value: formatDuration(item.recordingDuration)
      )
    }

    if let prompt = promptDuration {
      historyBadge(
        icon: "bolt.fill",
        title: "Prompt",
        value: formatDuration(prompt),
        tint: .purple
      )
    }

    if let cost = item.cost {
      historyBadge(
        icon: "creditcard",
        title: "Cost",
        value: formatCurrency(cost.total, currency: cost.currency),
        tint: .green
      )
    }

    if let error = errorBadgeInfo {
      historyBadge(
        icon: "exclamationmark.triangle.fill",
        title: error.title,
        value: error.value,
        tint: .orange
      )
    }
  }

  private func historyBadge(
    icon: String,
    title: String,
    value: String,
    tint: Color = .accentColor
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .imageScale(.medium)
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(tint)

      Text(value)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(tint.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.2), lineWidth: 1)
    )
  }
  private var promptDuration: TimeInterval? {
    let start =
      item.phaseTimestamps.transcriptionStarted
      ?? item.phaseTimestamps.recordingEnded
      ?? item.phaseTimestamps.recordingStarted
    let end =
      item.phaseTimestamps.outputDelivered
      ?? item.phaseTimestamps.postProcessingEnded
      ?? item.phaseTimestamps.transcriptionEnded

    guard let start, let end else { return nil }

    let duration = end.timeIntervalSince(start)
    guard duration.isFinite, duration > 0 else { return nil }

    return duration
  }

  private var errorBadgeInfo: (title: String, value: String)? {
    guard !item.errors.isEmpty else { return nil }
    if item.errors.count == 1 {
      let phase = item.errors.first?.phase.rawValue.capitalized ?? "Issue"
      return (title: "Error", value: phase)
    }
    return (title: "Errors", value: "\(item.errors.count) issues")
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let processed = processedTranscriptToDisplay {
        Text("Processed Transcript")
          .font(.subheadline.bold())
        transcriptBox(processed)
      }
      if let raw = item.rawTranscription {
        Text("Raw Transcript")
          .font(.subheadline.bold())
        transcriptBox(raw)
      }
    }
  }

  private var metaSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Session Details")
        .font(.subheadline.bold())

      LazyVGrid(columns: metaColumns, alignment: .leading, spacing: 12) {
        metaTile(icon: "bolt.horizontal.circle", title: "Trigger") {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.trigger.gesture.rawValue.capitalized)
            Text("Hotkey: \(item.trigger.hotKeyDescription)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let destination = item.trigger.destinationApplication {
          metaTile(icon: "app", title: "Destination") {
            Text(destination)
          }
        }

        if let models = modelsSummary {
          metaTile(icon: "brain.head.profile", title: "Models") {
            Text(models.replacingOccurrences(of: "\n", with: ", "))
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        metaTile(icon: "clock.arrow.circlepath", title: "Timeline") {
          if let start = item.phaseTimestamps.recordingStarted,
            let end = item.phaseTimestamps.outputDelivered
          {
            let total = end.timeIntervalSince(start)
            Text("Total: \(formatDuration(total))")
          } else {
            Text("Recording: \(formatDuration(item.recordingDuration))")
          }
        }

        if let cost = item.cost {
          metaTile(icon: "creditcard", title: "Cost") {
            VStack(alignment: .leading, spacing: 4) {
              Text(formatCurrency(cost.total, currency: cost.currency))
              if let breakdown = cost.breakdown {
                Text(
                  "Input tokens: \(breakdown.inputTokens) • Output: \(breakdown.outputTokens)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
  }

  private var modelsSummary: String? {
    guard !item.modelsUsed.isEmpty else { return nil }
    let friendly = item.modelsUsed.map { ModelCatalog.friendlyName(for: $0) }
    return friendly.joined(separator: "\n")
  }

  private func metaTile<Content: View>(
    icon: String,
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(Color.accentColor.opacity(0.8))
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      content()
        .font(.footnote)
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.accentColor.opacity(0.1), lineWidth: 1)
    )
  }

  private func transcriptBox(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(.body.monospaced())
      Button {
        copyToPasteboard(text)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
  }

  private var errorSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Errors")
        .font(.subheadline.bold())
      ForEach(item.errors) { error in
        VStack(alignment: .leading, spacing: 2) {
          Text(error.phase.rawValue.capitalized)
            .font(.caption.bold())
          Text(error.message)
          if let debug = error.debugDescription {
            Text(debug)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
      }
    }
  }

  private var networkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Network")
        .font(.subheadline.bold())
      ForEach(item.networkExchanges) { exchange in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("\(exchange.method) \(exchange.url.lastPathComponent)")
              .font(.callout.bold())
            Spacer()
            Text("HTTP \(exchange.responseCode)")
              .font(.caption.bold())
              .foregroundStyle(exchange.responseCode >= 400 ? .red : .secondary)
          }

          Divider()

          if !exchange.requestHeaders.isEmpty {
            Text("Request Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(formattedHeaders(exchange.requestHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.requestBodyPreview.isEmpty {
            Text("Request Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.requestBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
          }

          if !exchange.responseHeaders.isEmpty {
            Text("Response Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(formattedHeaders(exchange.responseHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.responseBodyPreview.isEmpty {
            Text("Response Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.responseBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.thinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
      }
    }
  }

  private var networkSummaryButton: some View {
    let count = item.networkExchanges.count
    let responseSummary: String
    if let last = item.networkExchanges.last {
      responseSummary = "Latest: HTTP \(last.responseCode)"
    } else {
      responseSummary = ""
    }

    return Button {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
        showNetworkDetails.toggle()
      }
    } label: {
      HStack(spacing: 12) {
        Label(
          showNetworkDetails ? "Hide API details" : "Show API details",
          systemImage: showNetworkDetails ? "chevron.up.circle.fill" : "chevron.down.circle"
        )
        .labelStyle(.titleAndIcon)
        .font(.callout.weight(.semibold))

        Spacer(minLength: 8)

        HStack(spacing: 6) {
          Text("\(count) request\(count == 1 ? "" : "s")")
          if !responseSummary.isEmpty {
            Text("•")
            Text(responseSummary)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.accentColor.opacity(0.09))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var footerActions: some View {
    HStack(spacing: 12) {
      if let url = item.audioFileURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }

        Button {
          Task { await environment.main.reprocessHistoryItem(item) }
        } label: {
          Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(environment.main.isBusy)
      }
      if environment.main.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .tint(Color.accentColor)
  }

  private func copyToPasteboard(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
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

  private func formatCurrency(_ value: Decimal, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.isEmpty ? "USD" : currency
    return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
  }

  private func formattedHeaders(_ headers: [String: String]) -> String {
    headers
      .sorted { $0.key < $1.key }
      .map { "\($0): \($1)" }
      .joined(separator: "\n")
  }

  private var processedTranscriptToDisplay: String? {
    guard
      let processed = item.postProcessedTranscription,
      !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    if let raw = item.rawTranscription,
      raw.trimmingCharacters(in: .whitespacesAndNewlines)
        == processed.trimmingCharacters(in: .whitespacesAndNewlines)
    {
      return nil
    }

    return processed
  }

  private var bestTranscript: String? {
    if let processed = processedTranscriptToDisplay {
      return processed
    }
    if let raw = item.rawTranscription,
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return raw
    }
    return nil
  }
}

private struct AudioPlaybackControls: View {
  @StateObject private var controller: AudioPlaybackController

  init(url: URL) {
    _controller = StateObject(wrappedValue: AudioPlaybackController(url: url))
  }

  var body: some View {
    HStack(spacing: 16) {
      Button(action: controller.togglePlayPause) {
        Label(
          controller.state == .playing ? "Pause" : "Play",
          systemImage: controller.state == .playing ? "pause.circle.fill" : "play.circle.fill"
        )
        .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)

      Button(action: controller.stop) {
        Label("Stop", systemImage: "stop.circle")
      }
      .buttonStyle(.bordered)
      .disabled(controller.state == .idle)

      Text(controller.formattedTime)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }
}

private final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
  enum PlaybackState {
    case idle
    case playing
    case paused
  }

  @Published private(set) var state: PlaybackState = .idle
  @Published private(set) var currentTime: TimeInterval = 0

  private var player: AVAudioPlayer?
  private var timer: Timer?

  init(url: URL) {
    super.init()
    configurePlayer(url: url)
  }

  deinit {
    timer?.invalidate()
    player?.stop()
  }

  func togglePlayPause() {
    guard let player else { return }
    switch state {
    case .playing:
      player.pause()
      state = .paused
      timer?.invalidate()
    case .paused:
      player.play()
      state = .playing
      startTimer()
    case .idle:
      player.currentTime = 0
      player.play()
      state = .playing
      startTimer()
    }
  }

  func stop() {
    guard let player else { return }
    player.stop()
    player.currentTime = 0
    state = .idle
    currentTime = 0
    timer?.invalidate()
  }

  var formattedTime: String {
    guard let duration = player?.duration, duration.isFinite else { return "--:--" }
    let current = currentTime
    let remaining = max(duration - current, 0)
    return "\(format(current)) / \(format(remaining))"
  }

  private func configurePlayer(url: URL) {
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      self.player = player
    } catch {
      player = nil
    }
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self, let player else { return }
      self.currentTime = player.currentTime
      if !player.isPlaying {
        self.state = .idle
        self.timer?.invalidate()
      }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func format(_ time: TimeInterval) -> String {
    guard time.isFinite else { return "--:--.--" }
    let hundredths = Int((time * 100).rounded())
    let minutes = hundredths / 6000
    let seconds = (hundredths / 100) % 60
    let fractional = hundredths % 100
    return String(format: "%02d:%02d.%02d", minutes, seconds, fractional)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    timer?.invalidate()
    currentTime = 0
    state = .idle
  }
}

// @Implement: This view presents the data available from the history manager. It shows a list of history items initially in a closed state that shows a minimal overview of that item but can be expanded to show the full details, including:
// - Copying the raw or post-processed transcript
// - Playing back the audio file showing the costs and models used and associated
// It also has the ability to philtre items using the History Manager and present all of that information back here.
// When a history item is expanded, there must be a button to expose the full API requests/responses that formed part of that transction.
