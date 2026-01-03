import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @State private var searchText: String = ""
  @State private var showErrorsOnly: Bool = false
  @State private var dateRangeEnabled: Bool = false
  @State private var startDate: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 24 * 60 * 60))
  @State private var endDate: Date = Date()
  @State private var historyItems: [HistoryItem] = []
  @State private var historyStats: HistoryStatistics = .init(
    totalSessions: 0,
    cumulativeRecordingDuration: 0,
    totalSpend: 0,
    averageSessionLength: 0,
    sessionsWithErrors: 0
  )
  @State private var showClearAllConfirmation: Bool = false
  @State private var isClearingAll: Bool = false
  @State private var showImportFiles: Bool = false
  @State private var isImportingFiles: Bool = false
  @State private var showImportAlert: Bool = false
  @State private var importAlertMessage: String?

  private func clearAllHistory(deleteRecordings: Bool) async {
    await MainActor.run { isClearingAll = true }
    if deleteRecordings {
      let recordings = await environment.audio.listRecordings()
      for recording in recordings {
        await environment.audio.removeRecording(at: recording.url)
      }
    }
    await environment.history.removeAll()
    await MainActor.run { isClearingAll = false }
  }

  @MainActor
  private func presentImportError(_ message: String) {
    importAlertMessage = message
    showImportAlert = true
  }

  private func importAudioFiles(_ urls: [URL]) async {
    await MainActor.run { isImportingFiles = true }
    defer {
      Task { @MainActor in
        isImportingFiles = false
      }
    }

    guard await environment.transcription.hasValidBatchAPIKey() else {
      await MainActor.run {
        presentImportError("Batch transcription requires an API key. Add one in Settings › API Keys.")
      }
      return
    }

    for url in urls {
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }

      do {
        let importedURL = try await environment.audio.importRecording(from: url)
        let duration = (try? AVAudioPlayer(contentsOf: importedURL).duration) ?? 0
        let trigger = HistoryTrigger(
          gesture: .uiButton,
          hotKeyDescription: "Import",
          outputMethod: .none,
          destinationApplication: nil
        )
        let placeholder = HistoryItem(
          modelsUsed: [],
          rawTranscription: nil,
          postProcessedTranscription: nil,
          recordingDuration: duration,
          cost: nil,
          audioFileURL: importedURL,
          networkExchanges: [],
          events: [],
          phaseTimestamps: PhaseTimestamps(
            recordingStarted: nil,
            recordingEnded: nil,
            transcriptionStarted: nil,
            transcriptionEnded: nil,
            postProcessingStarted: nil,
            postProcessingEnded: nil,
            outputDelivered: nil
          ),
          trigger: trigger,
          personalCorrections: nil,
          errors: [],
          source: .importedFile
        )
        await environment.main.reprocessHistoryItem(placeholder)
      } catch {
        await MainActor.run {
          presentImportError("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }
  }

  private var filteredItems: [HistoryItem] {
    var filter = HistoryFilter.none
    filter.searchText = searchText.isEmpty ? nil : searchText
    filter.includeErrorsOnly = showErrorsOnly
    if dateRangeEnabled {
      filter.dateRange = normalizedDateRange
    }
    return apply(filter: filter, to: historyItems)
  }

  private var normalizedDateRange: ClosedRange<Date> {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
    return start...end
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
        historyItems = environment.history.allItems
        historyStats = environment.history.statistics
      }
      .onReceive(environment.history.$items) { items in
        let previous = historyItems
        let updated = environment.history.allItems
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
          historyItems = updated
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
        colors: [Color.purple.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
    .confirmationDialog(
      "Clear All History",
      isPresented: $showClearAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) {
        Task { await clearAllHistory(deleteRecordings: false) }
      }
      Button("Clear History and Delete Recordings", role: .destructive) {
        Task { await clearAllHistory(deleteRecordings: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove all history entries. You can also delete all saved recordings. This action cannot be undone.")
    }
    .fileImporter(
      isPresented: $showImportFiles,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        Task { await importAudioFiles(urls) }
      case .failure(let error):
        presentImportError(error.localizedDescription)
      }
    }
    .alert("Import", isPresented: $showImportAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(importAlertMessage ?? "")
    }
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
            .speakTooltip("Search your past sessions by transcript, model, or keyword so you can quickly revisit the right moment.")
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
          .speakTooltip("Show only sessions where Speak spotted issues, making it easy to focus on what needs attention.")

        Toggle("Date range", isOn: $dateRangeEnabled)
          .toggleStyle(.switch)
          .tint(.white)
          .foregroundStyle(.white)
          .speakTooltip("Filter sessions to a specific date range.")

        if dateRangeEnabled {
          DatePicker("From", selection: $startDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
          DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
        }

        Spacer()

        if isImportingFiles {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          showImportFiles = true
        } label: {
          Label("Import…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.white.opacity(0.92))
        .foregroundStyle(Color.purple)
        .disabled(isClearingAll || isImportingFiles || environment.main.isBusy)
        .speakTooltip("Import existing audio files into history and transcribe them with your current settings.")

        Button {
          showClearAllConfirmation = true
        } label: {
          Label("Clear All", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(Color.purple)
        .disabled(historyItems.isEmpty || isClearingAll || isImportingFiles)
        .speakTooltip("Clear every saved session entry from this history view.")
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
        colors: [Color.purple, Color.indigo.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.purple.opacity(0.3), radius: 24, x: 0, y: 16)
  }

  private var emptyState: some View {
    VStack(spacing: 18) {
      Image(systemName: "waveform")
        .font(.system(size: 44, weight: .medium))
        .foregroundStyle(Color.purple)
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
        .stroke(Color.purple.opacity(0.15), lineWidth: 1)
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
  @State private var showDeleteConfirmation: Bool = false
  @FocusState private var isFocused: Bool

  var body: some View {
    rowContent
      .focusable()
      .focused($isFocused)
      .focusEffectDisabled()
      .contextMenu { contextMenuContent }
      .onChange(of: isExpanded) { _, expanded in
        if !expanded {
          showNetworkDetails = false
        }
      }
      .onKeyPress(.delete) {
        showDeleteConfirmation = true
        return .handled
      }
      .onKeyPress(keys: [KeyEquivalent("c")]) { press in
        if press.modifiers == [.command, .shift] {
          if let raw = item.rawTranscription {
            copyToPasteboard(raw)
          }
          return .handled
        } else if press.modifiers == .command {
          if let processed = item.postProcessedTranscription {
            copyToPasteboard(processed)
          } else if let raw = item.rawTranscription {
            copyToPasteboard(raw)
          }
          return .handled
        }
        return .ignored
      }
      .confirmationDialog(
        "Delete History Item",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          Task {
            await environment.history.remove(id: item.id)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete this history item? This action cannot be undone.")
      }
  }

  private var rowContent: some View {
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
            Button {
              showDeleteConfirmation = true
            } label: {
              Label("Delete", systemImage: "trash")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .speakTooltip("Delete this history item")
            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
              .imageScale(.large)
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color.purple, Color.purple.opacity(0.3))
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
              .speakTooltip("Copy the best available transcript")
            }
          } else {
            Text(previewText)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          if let models = modelsSummaryByPhase {
            Label(models, systemImage: "brain.head.profile")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .speakTooltip("Click to open or close full details for this session, including transcripts, costs, and network activity.")

      if isExpanded {
        expandedContent
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

  @ViewBuilder
  private var expandedContent: some View {
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

  @ViewBuilder
  private var contextMenuContent: some View {
    if let raw = item.rawTranscription {
      Button {
        copyToPasteboard(raw)
      } label: {
        Label("Copy Raw Transcription", systemImage: "doc.on.doc")
      }
    }

    if let processed = item.postProcessedTranscription {
      Button {
        copyToPasteboard(processed)
      } label: {
        Label("Copy Processed Transcription", systemImage: "doc.on.doc.fill")
      }
    }

    Divider()

    if item.audioFileURL != nil {
      Button {
        Task { await environment.main.reprocessHistoryItem(item) }
      } label: {
        Label("Re-process with Current Settings", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(environment.main.isBusy)
    }

    if let url = item.audioFileURL {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        Label("Play Audio", systemImage: "play.circle")
      }

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } label: {
        Label("Show in Finder", systemImage: "folder")
      }
    }

    Divider()

    Button(role: .destructive) {
      showDeleteConfirmation = true
    } label: {
      Label("Delete", systemImage: "trash")
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
    item.errors.isEmpty ? Color.purple.opacity(0.15) : Color.orange.opacity(0.35)
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

    if item.source == .importedFile {
      historyBadge(
        icon: "tray.and.arrow.down",
        title: "Source",
        value: "Imported",
        tint: .blue
      )
    }

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

        if !item.modelUsages.isEmpty {
          metaTile(icon: "brain.head.profile", title: "Models") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(groupedModelsByPhase, id: \.phase) { group in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text("\(group.phaseLabel):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(group.models)
                    .font(.caption)
                }
              }
            }
            .fixedSize(horizontal: false, vertical: true)
          }
        } else if let models = modelsSummary {
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
                Text("Input tokens: \(breakdown.inputTokens) • Output: \(breakdown.outputTokens)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      if let summary = item.personalCorrections,
        !(summary.applied.isEmpty && summary.suggestions.isEmpty)
      {
        personalCorrectionsSection(summary)
      }
    }
  }

  private func personalCorrectionsSection(_ summary: PersonalLexiconHistorySummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Corrections")
        .font(.caption.bold())

      if !summary.contextTags.isEmpty {
        Text("Context tags: \(summary.contextTags.joined(separator: ", "))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if let destination = summary.destinationApplication, !destination.isEmpty {
        Text("Destination context: \(destination)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if !summary.applied.isEmpty {
        correctionsList(
          title: "Applied",
          icon: "wand.and.stars",
          color: .green,
          records: summary.applied
        )
      }

      if !summary.suggestions.isEmpty {
        correctionsList(
          title: "Suggestions",
          icon: "hand.raised",
          color: .orange,
          records: summary.suggestions
        )
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }

  private func correctionsList(
    title: String,
    icon: String,
    color: Color,
    records: [PersonalLexiconCorrectionRecord]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon)
        .font(.caption.bold())
        .foregroundStyle(color)

      ForEach(records) { record in
        correctionsRow(record: record, color: color)
      }
    }
  }

  private func correctionsRow(record: PersonalLexiconCorrectionRecord, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
        Text("\(record.alias) -> \(record.canonical) (\(record.occurrences)x)")
        Spacer(minLength: 0)
        Text(record.confidence.rawValue.capitalized)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      .font(.caption)

      if let reason = record.reason, !reason.isEmpty {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
  private var modelsSummary: String? {
    guard !item.modelsUsed.isEmpty else { return nil }
    let friendly = item.modelsUsed.map { ModelCatalog.friendlyName(for: $0) }
    return friendly.joined(separator: "\n")
  }

  private var modelsSummaryByPhase: String? {
    guard !item.modelUsages.isEmpty else { return nil }

    let groups = Dictionary(grouping: item.modelUsages, by: { $0.phase })
      .sorted { phaseOrder($0.key) < phaseOrder($1.key) }

    let parts = groups.map { phase, usages in
      let models = usages.map { ModelCatalog.friendlyName(for: $0.modelIdentifier) }.joined(separator: ", ")
      return "\(phaseLabel(phase)): \(models)"
    }

    return parts.joined(separator: " • ")
  }

  private struct ModelsByPhase {
    let phase: ModelUsagePhase
    let phaseLabel: String
    let models: String
  }

  private var groupedModelsByPhase: [ModelsByPhase] {
    guard !item.modelUsages.isEmpty else { return [] }

    let groups = Dictionary(grouping: item.modelUsages, by: { $0.phase })
      .sorted { phaseOrder($0.key) < phaseOrder($1.key) }

    return groups.map { phase, usages in
      let models = usages.map { ModelCatalog.friendlyName(for: $0.modelIdentifier) }.joined(separator: ", ")
      return ModelsByPhase(phase: phase, phaseLabel: phaseLabel(phase), models: models)
    }
  }

  private func phaseLabel(_ phase: ModelUsagePhase) -> String {
    switch phase {
    case .transcriptionLive:
      return "Live"
    case .transcriptionBatch:
      return "Batch"
    case .postProcessing:
      return "Post-processing"
    }
  }

  private func phaseOrder(_ phase: ModelUsagePhase) -> Int {
    switch phase {
    case .transcriptionLive:
      return 0
    case .transcriptionBatch:
      return 1
    case .postProcessing:
      return 2
    }
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
          .foregroundStyle(Color.purple.opacity(0.8))
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
        .stroke(Color.purple.opacity(0.1), lineWidth: 1)
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
            .stroke(Color.purple.opacity(0.15), lineWidth: 1)
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
          .fill(Color.purple.opacity(0.09))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.purple.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .speakTooltip("Peek behind the scenes to review the API requests and responses that powered this session.")
  }

  private var footerActions: some View {
    HStack(spacing: 12) {
      if let url = item.audioFileURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .speakTooltip("Open the folder where this recording lives so you can manage or share the original audio.")

        Button {
          Task { await environment.main.reprocessHistoryItem(item) }
        } label: {
          Label {
            HStack(spacing: 6) {
              Text("Reprocess")
              Image(systemName: "questionmark.circle")
                .imageScale(.small)
            }
          } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(environment.main.isBusy)
        .speakTooltip("Sometimes on-device audio misses words. Reprocess sends this clip to our larger cloud models, which usually pick up every detail.")
      }
      if environment.main.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .tint(Color.purple)
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
      .speakTooltip("Tap to listen back and double-check what Speak heard for this session.")

      Button(action: controller.stop) {
        Label("Stop", systemImage: "stop.circle")
      }
      .buttonStyle(.bordered)
      .disabled(controller.state == .idle)
      .speakTooltip("Stop playback and reset the audio timer back to the beginning.")

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
