import AVFoundation
import AppKit
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var searchText: String = ""
  @State private var showErrorsOnly: Bool = false

  private var filteredItems: [HistoryItem] {
    var filter = HistoryFilter.none
    filter.searchText = searchText.isEmpty ? nil : searchText
    filter.includeErrorsOnly = showErrorsOnly
    return environment.history.items(matching: filter)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        if filteredItems.isEmpty {
          emptyState
        } else {
          LazyVStack(spacing: 20) {
            ForEach(filteredItems) { item in
              HistoryListRow(item: item)
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .center)
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
    let stats = environment.history.statistics
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
        .disabled(environment.history.items.isEmpty)
      }

      HStack(spacing: 16) {
        historyChip(title: "Sessions", value: "\(stats.totalSessions)")
        historyChip(title: "Errors", value: "\(stats.sessionsWithErrors)")
        historyChip(
          title: "Average Length",
          value: formattedDuration(stats.averageSessionLength)
        )
        historyChip(title: "Spend", value: formattedCurrency(stats.totalSpend))
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

  private func formattedDuration(_ duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }

  private func formattedCurrency(_ value: Decimal) -> String {
    guard value > 0 else { return "—" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    return formatter.string(from: value as NSDecimalNumber) ?? "—"
  }
}

private struct HistoryListRow: View {
  @EnvironmentObject private var environment: AppEnvironment
  let item: HistoryItem
  @State private var isExpanded: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Button {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(item.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.headline)
                .foregroundStyle(.primary)
              if !item.errors.isEmpty {
                Label("", systemImage: "exclamationmark.triangle.fill")
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.yellow)
              }
              Spacer(minLength: 0)
              HStack(spacing: 8) {
                HStack(spacing: 6) {
                  Image(systemName: "clock")
                  Text(formatDuration(item.recordingDuration))
                    .font(.callout.monospacedDigit())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                  Capsule()
                    .fill(Color.accentColor.opacity(0.12))
                )

                if let cost = item.cost {
                  HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                    Text(formatCurrency(cost.total, currency: cost.currency))
                      .font(.callout.monospacedDigit())
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color.green.opacity(0.15))
                  )
                }
              }
            }

            Text(previewText)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)

            HStack(spacing: 12) {
              if let models = modelsSummary {
                Label(
                  models.replacingOccurrences(of: "\n", with: ", "),
                  systemImage: "brain.head.profile"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              if !item.networkExchanges.isEmpty {
                Label(
                  item.networkExchanges.count == 1
                    ? "1 network call"
                    : "\(item.networkExchanges.count) network calls",
                  systemImage: "antenna.radiowaves.left.and.right"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              if let cost = item.cost?.total {
                Label(
                  formatCurrency(cost, currency: item.cost?.currency ?? "USD"),
                  systemImage: "creditcard"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }

          Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
            .imageScale(.large)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.accentColor, Color.accentColor.opacity(0.3))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Divider()
          .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 20) {
          metaSection

          if let url = item.audioFileURL {
            AudioPlaybackControls(url: url)
          }

          transcriptSection

          if !item.networkExchanges.isEmpty {
            networkSection
          }

          if !item.errors.isEmpty {
            errorSection
          }

          footerActions
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
  }

  private var previewText: String {
    if let processed = item.postProcessedTranscription, !processed.isEmpty {
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

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let processed = item.postProcessedTranscription {
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
    VStack(alignment: .leading, spacing: 12) {
      labeledRow(icon: "bolt.horizontal.circle", title: "Trigger") {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.trigger.gesture.rawValue.capitalized)
          Text("Hotkey: \(item.trigger.hotKeyDescription)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let models = modelsSummary {
        labeledRow(icon: "brain.head.profile", title: "Models") {
          Text(models)
            .multilineTextAlignment(.leading)
        }
      }

      if let cost = item.cost {
        labeledRow(icon: "creditcard", title: "Cost") {
          VStack(alignment: .leading, spacing: 4) {
            Text(formatCurrency(cost.total, currency: cost.currency))
            if let breakdown = cost.breakdown {
              Text("Input tokens: \(breakdown.inputTokens) • Output: \(breakdown.outputTokens)")
                .font(.caption)
                .foregroundStyle(.secondary)
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

  private func labeledRow<Content: View>(
    icon: String, title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(Color.accentColor)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        content()
      }
      Spacer()
    }
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
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02d:%02d", minutes, seconds)
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
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%02d:%02d", minutes, seconds)
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
