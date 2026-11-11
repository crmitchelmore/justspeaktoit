import SpeakCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The History page. Filtering and paging live in `HistoryListModel`, import
/// and clear-all in `HistoryLibraryActions`; this view wires them to the
/// history manager and lays out the page.
struct HistoryView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density
  @StateObject private var list = HistoryListModel()
  @StateObject private var library = HistoryLibraryActions()
  @State private var issueReportItem: HistoryItem?
  @State private var persistenceNotice: String?
  @State private var historyLoadState: HistoryLoadState = .loading
  @State private var historyStats: HistoryStatistics = .init(
    totalSessions: 0,
    cumulativeRecordingDuration: 0,
    totalSpend: 0,
    averageSessionLength: 0,
    sessionsWithErrors: 0
  )

  private var isInitialLoad: Bool {
    historyLoadState == .loading && list.items.isEmpty
  }

  private var historyLoadFailed: Bool {
    if case .failed = historyLoadState { return true }
    return false
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
          HistoryHeader(list: list, library: library, stats: historyStats, isSessionBusy: environment.main.isBusy)
          if let persistenceNotice {
            HistoryPersistenceBanner(
              notice: persistenceNotice,
              retry: historyLoadFailed ? { Task { await environment.history.retryLoad() } } : nil
            )
          }
          if isInitialLoad {
            HistorySkeletonList()
          } else if list.filteredItems.isEmpty {
            if list.isFilterActive {
              HistoryFilteredEmptyState(searchText: list.searchText, clearFilters: list.clearFilters)
            } else {
              HistoryEmptyState(
                isSessionBusy: environment.main.isBusy,
                startRecording: environment.main.toggleRecordingFromUI
              )
            }
          } else {
            historyRows
          }
        }
        .padding(density.pagePadding)
        .frame(maxWidth: 1100, alignment: .center)
      }
      .sheet(item: $issueReportItem) { HistoryIssueReportPreview(item: $0) }
      .onAppear {
        historyLoadState = environment.history.loadState
        list.show(environment.history.allItems)
        historyStats = environment.history.statistics
      }
      .onReceive(environment.history.$items) { items in
        let previous = list.items
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
          list.show(environment.history.allItems)
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
      .onReceive(environment.history.$persistenceError) { persistenceNotice = $0 }
      .onReceive(environment.history.$loadState) { state in
        historyLoadState = state
      }
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
      isPresented: $library.showClearAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) {
        Task { await library.clearAllHistory(deleteRecordings: false, in: environment) }
      }
      Button("Clear History and Delete Recordings", role: .destructive) {
        Task { await library.clearAllHistory(deleteRecordings: true, in: environment) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove all history entries. You can also delete all saved recordings. This action cannot be undone.")
    }
    .fileImporter(
      isPresented: $library.showImportFiles,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        Task { await library.importAudioFiles(urls, in: environment) }
      case .failure(let error):
        library.presentImportError(error.localizedDescription)
      }
    }
    .alert("Import", isPresented: $library.showImportAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(library.importAlertMessage ?? "")
    }
  }

  private var historyRows: some View {
    LazyVStack(spacing: density.sectionSpacing) {
      ForEach(list.displayedItems) { item in
        HistoryListRow(item: item) { issueReportItem = $0 }
          .id(item.id)
      }
      if list.hasMore {
        loadMoreFooter
      }
    }
    // Animate on IDs so the animation diff doesn't have to compare
    // full HistoryItem values (network exchanges, events, ...).
    .animation(.spring(response: 0.28, dampingFraction: 0.88), value: list.displayedItems.map(\.id))
  }

  /// Loads the next page when scrolled into view. Its identity follows the
  /// window, so it fires again if it is still on screen after a page loads.
  private var loadMoreFooter: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Showing \(list.displayedItems.count) of \(list.filteredItems.count) sessions")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("historyLoadMoreFooter")
    .id("history-load-more-\(list.pageWindow.limit)")
    .onAppear { list.loadMore() }
  }
}


// @Implement: This view presents the data available from the history manager. It shows a list of history items initially in a closed state that shows a minimal overview of that item but can be expanded to show the full details, including:
// - Copying the raw or post-processed transcript
// - Playing back the audio file showing the costs and models used and associated
// It also has the ability to philtre items using the History Manager and present all of that information back here.
// When a history item is expanded, there must be a button to expose the full API requests/responses that formed part of that transction.
