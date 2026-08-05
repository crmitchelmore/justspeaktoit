import Foundation
import os.log

// MARK: - HistoryWALStore

/// Isolated file I/O for HistoryManager's WAL and snapshot.
/// Keeps heavy Data encode/decode and FileHandle work off the MainActor
/// so `HistoryManager` (which owns @Published UI state) does not block
/// the main thread on disk I/O. All file coordination goes through this
/// single actor to avoid races between WAL appends and flushes.
actor HistoryWALStore {
    private let storageURL: URL
    private let walURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var walHandle: FileHandle?
    private let log = Logger(subsystem: "com.github.speakapp", category: "HistoryWALStore")

    init(storageURL: URL, walURL: URL) {
        self.storageURL = storageURL
        self.walURL = walURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        try? walHandle?.close()
    }

    // MARK: WAL append

    func append(_ entry: WALEntry) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let handle = try walFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            log.error("Failed to append to WAL: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Snapshot

    func writeSnapshot(_ items: [HistoryItem]) throws {
        let data = try encoder.encode(items)
        try data.write(to: storageURL, options: [.atomic])
    }

    func loadSnapshot() throws -> [HistoryItem] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let data = try Data(contentsOf: storageURL)
        return try decoder.decode([HistoryItem].self, from: data)
    }

    /// Persists a snapshot and removes only the WAL operations represented by it.
    /// Appends queued before or after this actor operation remain in the WAL
    /// unless their entry IDs are explicitly included in `entries`.
    func commitSnapshot(_ items: [HistoryItem], flushing entries: [WALEntry]) throws {
        try writeSnapshot(items)
        let flushedIDs = Set(entries.map(\.id))
        let remaining = try loadWALEntries().filter { !flushedIDs.contains($0.id) }
        try replaceWAL(with: remaining)
    }

    /// Replays and clears the WAL as one actor operation. Keeping the complete
    /// read/merge/write/clear sequence here prevents a concurrent append from
    /// being cleared without first being included in the snapshot.
    func replayWAL() throws -> [HistoryItem]? {
        let walEntries = try loadWALEntries()
        guard !walEntries.isEmpty else {
            if FileManager.default.fileExists(atPath: walURL.path) {
                try replaceWAL(with: [])
            }
            return nil
        }

        log.info("Replaying \(walEntries.count) WAL entries")
        var currentItems = try loadSnapshot()
        for entry in walEntries {
            switch entry.operation {
            case .append:
                if let item = entry.item, !currentItems.contains(where: { $0.id == item.id }) {
                    currentItems.insert(item, at: 0)
                }
            case .update:
                if let item = entry.item,
                   let index = currentItems.firstIndex(where: { $0.id == item.id }) {
                    currentItems[index] = item
                }
            case .remove:
                if let item = entry.item { currentItems.removeAll { $0.id == item.id } }
            case .removeAll:
                currentItems.removeAll()
            }
        }

        try writeSnapshot(currentItems)
        try replaceWAL(with: [])
        log.info("WAL replay complete, cleared WAL file")
        return currentItems
    }

    func loadWALEntries() throws -> [WALEntry] {
        guard FileManager.default.fileExists(atPath: walURL.path) else { return [] }
        try walHandle?.synchronize()
        let data = try Data(contentsOf: walURL)
        return decodeWALEntries(from: data)
    }

    // MARK: Private

    private func walFileHandle() throws -> FileHandle {
        if let walHandle { return walHandle }
        if !FileManager.default.fileExists(atPath: walURL.path) {
            FileManager.default.createFile(atPath: walURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: walURL)
        walHandle = handle
        return handle
    }

    private func replaceWAL(with entries: [WALEntry]) throws {
        try walHandle?.close()
        walHandle = nil

        guard !entries.isEmpty else {
            if FileManager.default.fileExists(atPath: walURL.path) {
                try FileManager.default.removeItem(at: walURL)
            }
            return
        }

        var data = Data()
        for entry in entries {
            try data.append(encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: walURL, options: [.atomic])
    }

    private func decodeWALEntries(from data: Data) -> [WALEntry] {
        if let legacy = try? decoder.decode([WALEntry].self, from: data) { return legacy }
        var entries: [WALEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let entry = try? decoder.decode(WALEntry.self, from: Data(line)) {
                entries.append(entry)
            } else if let legacy = try? decoder.decode([WALEntry].self, from: Data(line)) {
                entries.append(contentsOf: legacy)
            }
        }
        return entries
    }
}
