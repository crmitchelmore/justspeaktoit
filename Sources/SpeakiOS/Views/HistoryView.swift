#if os(iOS)
import SwiftUI
import SpeakSync

// MARK: - History View

public struct HistoryView: View {
    @StateObject private var historyManager = iOSHistoryManager.shared
    @ObservedObject private var syncEngine = HistorySyncEngine.shared
    @State private var showingClearConfirmation = false
    @State private var showSkeletonLoading = false

    public init() {}

    public var body: some View {
        Group {
            if showSkeletonLoading {
                skeletonLoadingView
            } else if historyManager.isLoading {
                ProgressView("Loading history...")
            } else if historyManager.items.isEmpty {
                emptyState
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
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .refreshable {
            await historyManager.triggerSync()
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
                ForEach(historyManager.items) { item in
                    HistoryItemRow(
                        item: item,
                        isSynced: historyManager.isSynced(item)
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
                            UIPasteboard.general.string = item.transcription
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
        HStack(spacing: 20) {
            statBadge(
                value: "\(historyManager.items.count)",
                label: "Transcriptions"
            )
            statBadge(
                value: formatDuration(totalDuration),
                label: "Total Time"
            )
            statBadge(
                value: "\(totalWords)",
                label: "Words"
            )
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

    private var totalDuration: TimeInterval {
        historyManager.items.reduce(0) { $0 + $1.duration }
    }

    private var totalWords: Int {
        historyManager.items.reduce(0) { $0 + $1.wordCount }
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

#Preview {
    NavigationStack {
        HistoryView()
    }
}
#endif
