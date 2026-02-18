#if os(iOS)
import Foundation
import SpeakSync
import SwiftUI

// MARK: - History Item Model

/// A single transcription history entry for iOS.
public struct iOSHistoryItem: Identifiable, Codable {
    public let id: UUID
    public let createdAt: Date
    public let transcription: String
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcription: String,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcription = transcription
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
    }

    /// Convert to a syncable entry for CloudKit.
    func toSyncable() -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: transcription,
            postProcessedText: nil,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            updatedAt: createdAt
        )
    }

    /// Create from a synced remote entry.
    static func fromSyncable(_ entry: SyncableHistoryEntry) -> iOSHistoryItem {
        let text = entry.postProcessedText
            ?? entry.rawTranscription
            ?? ""
        return iOSHistoryItem(
            id: entry.id,
            createdAt: entry.createdAt,
            transcription: text,
            model: entry.model,
            duration: entry.duration,
            wordCount: entry.wordCount,
            originPlatform: entry.originPlatform
        )
    }
}

// MARK: - History Manager

/// Manages transcription history persistence for iOS with CloudKit sync.
@MainActor
public final class iOSHistoryManager: ObservableObject {
    public static let shared = iOSHistoryManager()

    @Published public private(set) var items: [iOSHistoryItem] = []
    @Published public private(set) var isLoading = false

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// IDs of entries that have been synced to CloudKit.
    private(set) var syncedIDs: Set<UUID> = []
    private let syncedIDsKey = "speak.sync.syncedHistoryIDs"

    /// Number of entries synced to CloudKit.
    public var syncedCount: Int { syncedIDs.count }

    /// Number of entries not yet synced.
    public var unsyncedCount: Int {
        items.filter { !syncedIDs.contains($0.id) }.count
    }

    /// Whether a specific item has been synced.
    public func isSynced(_ item: iOSHistoryItem) -> Bool {
        syncedIDs.contains(item.id)
    }

    private init() {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        self.fileURL = documentsURL.appendingPathComponent(
            "transcription-history.json"
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSyncedIDs()

        Task {
            await loadHistory()
            await initializeSync()
        }
    }

    // MARK: - CloudKit Sync Init

    private func initializeSync() async {
        await HistorySyncEngine.shared.initialize(delegate: self)
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Public API

    /// Adds a new transcription to history.
    public func add(_ item: iOSHistoryItem) {
        items.insert(item, at: 0)
        saveHistory()

        // Upload to CloudKit in background
        Task {
            try? await HistorySyncEngine.shared.upload(
                entry: item.toSyncable()
            )
            syncedIDs.insert(item.id)
            saveSyncedIDs()
        }
    }

    /// Creates and adds a history item from transcription result.
    public func recordTranscription(
        text: String,
        model: String,
        duration: TimeInterval
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let item = iOSHistoryItem(
            transcription: text,
            model: model,
            duration: duration,
            wordCount: text.split(separator: " ").count
        )
        add(item)
    }

    /// Removes an item from history.
    public func remove(_ item: iOSHistoryItem) {
        items.removeAll { $0.id == item.id }
        saveHistory()

        // Delete from CloudKit in background
        Task {
            try? await HistorySyncEngine.shared.delete(entryID: item.id)
            syncedIDs.remove(item.id)
            saveSyncedIDs()
        }
    }

    /// Clears all history.
    public func clearAll() {
        let allIDs = items.map(\.id)
        items.removeAll()
        saveHistory()

        // Delete all from CloudKit in background
        Task {
            for entryID in allIDs {
                try? await HistorySyncEngine.shared.delete(entryID: entryID)
            }
            syncedIDs.removeAll()
            saveSyncedIDs()
        }
    }

    /// Trigger a manual sync.
    public func triggerSync() async {
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Persistence

    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try decoder.decode([iOSHistoryItem].self, from: data)
        } catch {
            print("[iOSHistoryManager] Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[iOSHistoryManager] Failed to save history: \(error)")
        }
    }

    // MARK: - Synced IDs Tracking

    private func loadSyncedIDs() {
        if let strings = UserDefaults.standard.stringArray(
            forKey: syncedIDsKey
        ) {
            syncedIDs = Set(strings.compactMap { UUID(uuidString: $0) })
        }
    }

    private func saveSyncedIDs() {
        let strings = syncedIDs.map(\.uuidString)
        UserDefaults.standard.set(strings, forKey: syncedIDsKey)
    }
}

// MARK: - HistorySyncDelegate

extension iOSHistoryManager: HistorySyncDelegate {
    public func pendingEntries() -> [SyncableHistoryEntry] {
        items
            .filter { !syncedIDs.contains($0.id) }
            .map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) {
        // Skip if we already have this entry
        guard !items.contains(where: { $0.id == entry.id }) else {
            return
        }

        let item = iOSHistoryItem.fromSyncable(entry)
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        saveHistory()
        syncedIDs.insert(entry.id)
        saveSyncedIDs()
    }

    public func didDeleteRemoteEntry(id: UUID) {
        items.removeAll { $0.id == id }
        saveHistory()
        syncedIDs.remove(id)
        saveSyncedIDs()
    }
}

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
                syncStatusView
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
            // Show skeleton loading briefly for improved perceived performance
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
    private var syncStatusView: some View {
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
            // Stats header skeleton
            Section {
                HistoryStatsSkeleton()
                    .listRowInsets(EdgeInsets())
            }
            
            // History items skeleton
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
            // Sync status banner
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

            // Stats header
            Section {
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
            
            // History items
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

// MARK: - History Item Row

struct HistoryItemRow: View {
    let item: iOSHistoryItem
    let isSynced: Bool
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Sync indicator
                    Image(systemName: isSynced ? "icloud.fill" : "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(isSynced ? .green : .secondary.opacity(0.5))

                    Label("\(item.wordCount)", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(formatDuration(item.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Transcription preview/full
            Text(item.transcription)
                .font(.body)
                .lineLimit(isExpanded ? nil : 3)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            
            // Model badge
            HStack {
                Text(modelDisplayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                
                if item.originPlatform != "ios" {
                    Text(platformDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                }
                
                Spacer()
                
                if item.transcription.count > 150 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.transcription.count > 150 {
                isExpanded.toggle()
            }
        }
    }
    
    private var modelDisplayName: String {
        if item.model.contains("deepgram") {
            return "Deepgram"
        } else if item.model.contains("apple") {
            return "Apple Speech"
        }
        return item.model
    }

    private var platformDisplayName: String {
        switch item.originPlatform {
        case "macos":
            return "Mac"
        case "ios":
            return "iPhone"
        default:
            return item.originPlatform
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}

// MARK: - Sync Status Banner

struct SyncStatusBanner: View {
    @ObservedObject var syncEngine: HistorySyncEngine
    let syncedCount: Int
    let unsyncedCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: syncIcon)
                    .foregroundStyle(syncIconColor)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncEngine.state.statusMessage)
                        .font(.subheadline.weight(.medium))
                    Text(syncSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if syncEngine.state.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Progress bar
            if totalCount > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 4)
                        Capsule()
                            .fill(syncBarColor)
                            .frame(
                                width: geometry.size.width * syncFraction,
                                height: 4
                            )
                    }
                }
                .frame(height: 4)
            }

            if let error = syncEngine.state.error {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var syncFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(syncedCount) / CGFloat(totalCount)
    }

    private var syncSummary: String {
        if totalCount == 0 {
            return "No entries"
        }
        if unsyncedCount == 0 {
            return "All \(totalCount) entries synced"
        }
        return "\(syncedCount) of \(totalCount) synced · \(unsyncedCount) pending"
    }

    private var syncIcon: String {
        if syncEngine.state.isSyncing {
            return "arrow.triangle.2.circlepath.icloud"
        }
        if syncEngine.state.error != nil {
            return "exclamationmark.icloud"
        }
        if unsyncedCount == 0, totalCount > 0 {
            return "checkmark.icloud.fill"
        }
        return "icloud.fill"
    }

    private var syncIconColor: Color {
        if syncEngine.state.error != nil {
            return .orange
        }
        if unsyncedCount == 0, totalCount > 0 {
            return .green
        }
        return .blue
    }

    private var syncBarColor: Color {
        if syncEngine.state.error != nil {
            return .orange
        }
        return .green
    }
}

#endif
