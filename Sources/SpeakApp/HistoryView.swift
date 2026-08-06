import SpeakCore
import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
// swiftlint:disable file_length

struct HistoryView: View { // swiftlint:disable:this type_body_length
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var searchText: String = ""
  @State private var showErrorsOnly: Bool = false
  @State private var dateRangeEnabled: Bool = false
  @State private var startDate: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 24 * 60 * 60))
  @State private var endDate: Date = Date()
  @State private var historyItems: [HistoryItem] = []
  @State private var selectedModelFilter: String? = nil
  @State private var availableModels: [String] = []
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
  @State private var isInitialLoad: Bool = true

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

  /// Filtered items cached in state so a body pass doesn't re-filter the full
  /// history several times per render; recomputed when the source items or any
  /// filter input change.
  @State private var filteredItems: [HistoryItem] = []

  private func recomputeFilteredItems() {
    var filter = HistoryFilter.none
    filter.searchText = searchText.isEmpty ? nil : searchText
    filter.includeErrorsOnly = showErrorsOnly
    if let model = selectedModelFilter {
      filter.modelIdentifiers = [model]
    }
    if dateRangeEnabled {
      filter.dateRange = normalizedDateRange
    }
    filteredItems = apply(filter: filter, to: historyItems)
  }

  /// All unique models used across history items, cached to avoid re-computing on every render.
  private func computeAvailableModels(from items: [HistoryItem]) -> [String] {
    let unique = Set(items.flatMap { $0.modelsUsed })
    return unique.sorted { ModelCatalog.friendlyName(for: $0) < ModelCatalog.friendlyName(for: $1) }
  }

  private var normalizedDateRange: ClosedRange<Date> {
    HistorySearchQuery.normalizedDayRange(from: startDate, through: endDate)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
          header
          if isInitialLoad {
            skeletonLoadingView
          } else if filteredItems.isEmpty {
            emptyState
          } else {
            LazyVStack(spacing: density.sectionSpacing) {
              ForEach(filteredItems) { item in
                HistoryListRow(item: item)
                  .id(item.id)
              }
            }
            // Animate on IDs so the animation diff doesn't have to compare
            // full HistoryItem values (network exchanges, events, ...).
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: filteredItems.map(\.id))
          }
        }
        .padding(density.pagePadding)
        .frame(maxWidth: 1100, alignment: .center)
      }
      .onAppear {
        historyItems = environment.history.allItems
        recomputeFilteredItems()
        availableModels = computeAvailableModels(from: historyItems)
        historyStats = environment.history.statistics
        // Delay to show skeleton briefly for improved perceived performance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          withAnimation(.easeOut(duration: 0.3)) {
            isInitialLoad = false
          }
        }
      }
      .onReceive(environment.history.$items) { items in
        let previous = historyItems
        let updated = environment.history.allItems
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
          historyItems = updated
          recomputeFilteredItems()
        }
        availableModels = computeAvailableModels(from: updated)
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
      .onChange(of: searchText) { _, _ in recomputeFilteredItems() }
      .onChange(of: showErrorsOnly) { _, _ in recomputeFilteredItems() }
      .onChange(of: selectedModelFilter) { _, _ in recomputeFilteredItems() }
      .onChange(of: dateRangeEnabled) { _, _ in recomputeFilteredItems() }
      .onChange(of: startDate) { _, _ in recomputeFilteredItems() }
      .onChange(of: endDate) { _, _ in recomputeFilteredItems() }

    }
    .background(
      LinearGradient(
        colors: [Color.brandAccent.opacity(0.06), Color(nsColor: .windowBackgroundColor)],
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


  @ViewBuilder
  private var header: some View {
    if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
      compactHeader
    } else {
      normalHeader
    }
  }

  private var compactHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: density.inlineSpacing) {
        Label("History", systemImage: "clock.arrow.circlepath")
          .font(.subheadline.bold())

        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search", text: $searchText)
            .textFieldStyle(.plain)
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        Toggle(isOn: $showErrorsOnly) {
          Label("Errors only", systemImage: showErrorsOnly
            ? "exclamationmark.triangle.fill"
            : "exclamationmark.triangle")
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .speakTooltip("Show sessions with errors")

        Toggle(isOn: $dateRangeEnabled) {
          Label("Date range", systemImage: dateRangeEnabled ? "calendar.badge.checkmark" : "calendar")
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .speakTooltip("Filter by date range")

        if dateRangeEnabled {
          DatePicker("From", selection: $startDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
          DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
        }

        if !availableModels.isEmpty {
          Picker("Model", selection: $selectedModelFilter) {
            Text("All Models").tag(String?.none)
            Divider()
            ForEach(availableModels, id: \.self) { model in
              Text(ModelCatalog.friendlyName(for: model)).tag(String?.some(model))
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
          .speakTooltip("Filter by model")
        }

        Spacer(minLength: 2)

        if isImportingFiles {
          ProgressView()
            .controlSize(.mini)
        }

        Button {
          showImportFiles = true
        } label: {
          Label("Import", systemImage: "square.and.arrow.down")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(isClearingAll || isImportingFiles || environment.main.isBusy)
        .speakTooltip("Import audio")
        .accessibilityLabel("Import audio")
        .accessibilityAddTraits(.isButton)

        Button {
          showClearAllConfirmation = true
        } label: {
          Label("Clear All", systemImage: "trash")
            .labelStyle(.iconOnly)
            .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .disabled(historyItems.isEmpty || isClearingAll || isImportingFiles)
        .speakTooltip("Clear all history")
        .accessibilityLabel("Clear all history")
        .accessibilityHint("Opens a confirmation before deleting all history items")
        .accessibilityAddTraits(.isButton)
      }

      HStack(spacing: density.groupSpacing) {
        compactHistoryMetric(
          title: "Sessions",
          value: "\(historyStats.totalSessions)",
          systemImage: "record.circle"
        )
        compactHistoryMetric(
          title: "Errors",
          value: "\(historyStats.sessionsWithErrors)",
          systemImage: "exclamationmark.triangle"
        )
        compactHistoryMetric(
          title: "Average",
          value: formattedDuration(historyStats.averageSessionLength),
          systemImage: "timer"
        )
        compactHistoryMetric(
          title: "Spend",
          value: formattedCurrency(historyStats.totalSpend),
          systemImage: "creditcard"
        )
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

  private func compactHistoryMetric(
    title: String,
    value: String,
    systemImage: String
  ) -> some View {
    Label(value, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("\(title): \(value)")
  }

  private var normalHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
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
          .tint(.brandAccentWarm)
          .foregroundStyle(.white)
          .speakTooltip("Show only sessions where Speak spotted issues, making it easy to focus on what needs attention.")

        Toggle("Date range", isOn: $dateRangeEnabled)
          .toggleStyle(.switch)
          .tint(.brandAccentWarm)
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

        if !availableModels.isEmpty {
          Picker("Model", selection: $selectedModelFilter) {
            Text("All Models").tag(String?.none)
            Divider()
            ForEach(availableModels, id: \.self) { model in
              Text(ModelCatalog.friendlyName(for: model)).tag(String?.some(model))
            }
          }
          .pickerStyle(.menu)
          .tint(.white)
          .speakTooltip("Filter sessions by the transcription or processing model used.")
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
        .tint(.brandAccentWarm)
        .foregroundStyle(Color.brandAccentDeep)
        .disabled(isClearingAll || isImportingFiles || environment.main.isBusy)
        .speakTooltip("Import existing audio files into history and transcribe them with your current settings.")

        Button {
          showClearAllConfirmation = true
        } label: {
          Label("Clear All", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.brandAccentWarm)
        .foregroundStyle(Color.brandAccentDeep)
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
        colors: [Color.brandAccentDeep, Color.brandAccentWarm.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.brandAccent.opacity(0.3), radius: 24, x: 0, y: 16)
  }

  private var emptyState: some View {
    VStack(spacing: density.isCompact ? 6 : 18) {
      Image(systemName: "waveform")
        .font(.system(size: density.isCompact ? 22 : 44, weight: .medium))
        .foregroundStyle(Color.brandAccent)
      Text("No history yet")
        .font(density.isCompact ? .subheadline.bold() : .title2.bold())
      if !density.isCompact {
        Text("Record a session to see transcripts, costs, and network activity appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Button(action: environment.main.toggleRecordingFromUI) {
        if density.isCompact {
          Label("Start a recording", systemImage: "mic.fill")
            .labelStyle(.iconOnly)
        } else {
          Label("Start a recording", systemImage: "mic.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(environment.main.isBusy)
    }
    .frame(maxWidth: .infinity)
    .padding(density.isCompact ? 12 : 40)
    .background(
      RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
        .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
    )
  }

  private var skeletonLoadingView: some View {
    VStack(spacing: density.sectionSpacing) {
      // Stats header skeleton
      HistoryStatsSkeleton()
        .padding(.bottom, density.isCompact ? 0 : 8)
      
      // History items skeleton
      ForEach(0..<3, id: \.self) { _ in
        HistoryItemSkeleton()
          .padding(density.isCompact ? 6 : 16)
          .background(
            RoundedRectangle(cornerRadius: density.isCompact ? 8 : 20, style: .continuous)
              .fill(.ultraThinMaterial)
          )
          .overlay(
            RoundedRectangle(cornerRadius: density.isCompact ? 8 : 20, style: .continuous)
              .stroke(Color.brandAccent.opacity(0.1), lineWidth: 1)
          )
      }
    }
    .frame(maxWidth: .infinity)
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
    items.filter { filter.matches($0.presentationItem) }
  }
}

// @Implement: This view presents the data available from the history manager. It shows a list of history items initially in a closed state that shows a minimal overview of that item but can be expanded to show the full details, including:
// - Copying the raw or post-processed transcript
// - Playing back the audio file showing the costs and models used and associated
// It also has the ability to philtre items using the History Manager and present all of that information back here.
// When a history item is expanded, there must be a button to expose the full API requests/responses that formed part of that transction.
