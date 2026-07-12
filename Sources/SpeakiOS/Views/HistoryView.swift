#if os(iOS)
import SwiftUI
import SpeakCore
import SpeakSync

// MARK: - History View

// swiftlint:disable:next type_body_length
public struct HistoryView: View {
    @StateObject private var historyManager = iOSHistoryManager.shared
    @ObservedObject private var syncEngine = HistorySyncEngine.shared
    @State private var showingClearConfirmation = false
    @State private var showSkeletonLoading = false
    @State private var showingFilters = false
    @State private var searchText = ""
    @State private var errorsOnly = false
    @State private var selectedModel: String?
    @State private var dateRangeEnabled = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var filteredItems: [iOSHistoryItem] = []
    @State private var statistics = HistoryPresentationStatistics(items: [])
    @State private var availableModels: [String] = []
    @State private var derivedStateReady = false

    public init() {}

    public var body: some View {
        Group {
            if showSkeletonLoading {
                skeletonLoadingView
            } else if historyManager.isLoading {
                ProgressView("Loading history...")
            } else if historyManager.items.isEmpty {
                emptyState
            } else if !derivedStateReady {
                ProgressView("Preparing history...")
            } else if filteredItems.isEmpty {
                noMatchesState
            } else {
                historyList
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                syncStatusIcon
            }
            if !historyManager.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(
                            systemName: hasActiveFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .accessibilityLabel("Filter history")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Transcripts or models")
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                HistoryFilterSheet(
                    errorsOnly: $errorsOnly,
                    selectedModel: $selectedModel,
                    dateRangeEnabled: $dateRangeEnabled,
                    startDate: $startDate,
                    endDate: $endDate,
                    availableModels: availableModels
                )
            }
            .presentationDetents([.medium, .large])
        }
        .refreshable {
            await historyManager.triggerSync()
        }
        .task(id: refreshKey) {
            refreshDerivedState()
        }
        .confirmationDialog(
            "Clear History",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                historyManager.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(historyManager.items.count) transcriptions.")
        }
        .onAppear {
            if historyManager.items.isEmpty && !historyManager.isLoading {
                showSkeletonLoading = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSkeletonLoading = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusIcon: some View {
        if syncEngine.state.isSyncing {
            ProgressView()
                .controlSize(.small)
        } else if syncEngine.state.isCloudAvailable {
            Image(systemName: "icloud.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var skeletonLoadingView: some View {
        List {
            Section {
                HistoryStatsSkeleton()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(0..<5, id: \.self) { _ in
                    iOSHistoryItemSkeleton()
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No History", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Your transcriptions will appear here")
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private var historyList: some View {
        List {
            if syncEngine.state.isCloudAvailable {
                Section {
                    SyncStatusBanner(
                        syncEngine: syncEngine,
                        syncedCount: historyManager.syncedCount,
                        unsyncedCount: historyManager.unsyncedCount,
                        totalCount: historyManager.items.count
                    )
                }
            }
            Section {
                statsHeader
            }
            Section {
                ForEach(filteredItems) { item in
                    HistoryItemRow(
                        item: item,
                        isSynced: historyManager.isSynced(item),
                        isReprocessing: historyManager.isReprocessing(item),
                        onCopyRaw: { UIPasteboard.general.string = item.transcription },
                        onCopyPolished: {
                            UIPasteboard.general.string = item.postProcessedTranscription ?? item.transcription
                        },
                        onReprocess: { Task { await historyManager.reprocess(item) } },
                        onDelete: { historyManager.remove(item) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            historyManager.remove(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            UIPasteboard.general.string = item.bestText
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }

    private var statsHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                statBadge(value: "\(statistics.totalSessions)", label: "Sessions")
                statBadge(value: formatDuration(statistics.averageSessionLength), label: "Average")
                statBadge(value: formatDuration(statistics.cumulativeRecordingDuration), label: "Total Time")
                statBadge(value: "\(statistics.totalWords)", label: "Words")
                statBadge(value: "\(statistics.sessionsWithErrors)", label: "Errors")
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var query: HistorySearchQuery {
        let range: ClosedRange<Date>?
        if dateRangeEnabled {
            range = HistorySearchQuery.normalizedDayRange(from: startDate, through: endDate)
        } else {
            range = nil
        }
        return HistorySearchQuery(
            searchText: searchText,
            modelIdentifiers: selectedModel.map { [$0] } ?? [],
            includeErrorsOnly: errorsOnly,
            dateRange: range
        )
    }

    private var refreshKey: HistoryRefreshKey {
        HistoryRefreshKey(
            items: historyManager.items.map(\.presentationItem),
            searchText: searchText,
            errorsOnly: errorsOnly,
            selectedModel: selectedModel,
            dateRangeEnabled: dateRangeEnabled,
            startDate: startDate,
            endDate: endDate
        )
    }

    private func refreshDerivedState() {
        let currentQuery = query
        let newItems = historyManager.items.filter { currentQuery.matches($0.presentationItem) }
        filteredItems = newItems
        statistics = HistoryPresentationStatistics(items: newItems.map(\.presentationItem))
        availableModels = Array(Set(historyManager.items.map(\.model))).sorted {
            ModelCatalog.friendlyName(for: $0) < ModelCatalog.friendlyName(for: $1)
        }
        derivedStateReady = true
    }

    private var hasActiveFilters: Bool {
        errorsOnly || selectedModel != nil || dateRangeEnabled
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

private struct HistoryRefreshKey: Hashable {
    let items: [HistoryPresentationItem]
    let searchText: String
    let errorsOnly: Bool
    let selectedModel: String?
    let dateRangeEnabled: Bool
    let startDate: Date
    let endDate: Date
}

private struct HistoryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var errorsOnly: Bool
    @Binding var selectedModel: String?
    @Binding var dateRangeEnabled: Bool
    @Binding var startDate: Date
    @Binding var endDate: Date
    let availableModels: [String]

    var body: some View {
        Form {
            Section("Show") {
                Toggle("Errors only", isOn: $errorsOnly)
                Picker("Model", selection: $selectedModel) {
                    Text("All Models").tag(String?.none)
                    ForEach(availableModels, id: \.self) { model in
                        Text(ModelCatalog.friendlyName(for: model)).tag(String?.some(model))
                    }
                }
            }

            Section("Date Range") {
                Toggle("Limit by date", isOn: $dateRangeEnabled)
                if dateRangeEnabled {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                    DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
            }

            if errorsOnly || selectedModel != nil || dateRangeEnabled {
                Section {
                    Button("Reset Filters", role: .destructive) {
                        errorsOnly = false
                        selectedModel = nil
                        dateRangeEnabled = false
                    }
                }
            }
        }
        .navigationTitle("Filter History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
#endif
