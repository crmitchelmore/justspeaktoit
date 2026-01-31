#if os(iOS)
import Foundation
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
    
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcription: String,
        model: String,
        duration: TimeInterval,
        wordCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcription = transcription
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
    }
}

// MARK: - History Manager

/// Manages transcription history persistence for iOS.
@MainActor
public final class iOSHistoryManager: ObservableObject {
    public static let shared = iOSHistoryManager()
    
    @Published public private(set) var items: [iOSHistoryItem] = []
    @Published public private(set) var isLoading = false
    
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documentsURL.appendingPathComponent("transcription-history.json")
        
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        
        Task {
            await loadHistory()
        }
    }
    
    // MARK: - Public API
    
    /// Adds a new transcription to history.
    public func add(_ item: iOSHistoryItem) {
        items.insert(item, at: 0)
        saveHistory()
    }
    
    /// Creates and adds a history item from transcription result.
    public func recordTranscription(
        text: String,
        model: String,
        duration: TimeInterval
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
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
    }
    
    /// Clears all history.
    public func clearAll() {
        items.removeAll()
        saveHistory()
    }
    
    // MARK: - Persistence
    
    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
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
}

// MARK: - History View

public struct HistoryView: View {
    @StateObject private var historyManager = iOSHistoryManager.shared
    @State private var showingClearConfirmation = false
    
    public init() {}
    
    public var body: some View {
        Group {
            if historyManager.isLoading {
                ProgressView("Loading history...")
            } else if historyManager.items.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .navigationTitle("History")
        .toolbar {
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
                    HistoryItemRow(item: item)
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
#endif
