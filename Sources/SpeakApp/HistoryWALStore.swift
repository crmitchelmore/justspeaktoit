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

    init(storageURL: URL, walURL: URL, encoder: JSONEncoder, decoder: JSONDecoder) {
        self.storageURL = storageURL
        self.walURL = walURL
        self.encoder = encoder
        self.decoder = decoder
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

    func rewrite(with entries: [WALEntry]) {
        do {
            try walHandle?.close()
            walHandle = nil
            var data = Data()
            for entry in entries {
                try data.append(encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: walURL, options: [.atomic])
        } catch {
            log.error("Failed to rewrite WAL: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        do {
            try walHandle?.close()
            walHandle = nil
            if FileManager.default.fileExists(atPath: walURL.path) {
                try FileManager.default.removeItem(at: walURL)
            }
        } catch {
            log.error("Failed to clear WAL: \(error.localizedDescription, privacy: .public)")
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
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    func loadWALEntries() throws -> [WALEntry] {
        guard FileManager.default.fileExists(atPath: walURL.path) else { return [] }
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
