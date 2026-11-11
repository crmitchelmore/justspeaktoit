import Foundation
import SpeakCore
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
    private let log = SpeakLogger.logger(category: "HistoryWALStore")

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

    /// Appends one entry to the WAL. Throws on any encode or I/O failure so the
    /// caller can refuse to treat the mutation as durable (issue #695); the
    /// entry stays in the manager's pending queue and is retried by flush.
    func append(_ entry: WALEntry) throws {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let handle = try walFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            log.error("Failed to append to WAL: \(error.localizedDescription, privacy: .public)")
            throw error
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
    ///
    /// The WAL is read and validated *before* the snapshot is replaced, so a
    /// late WAL read failure cannot leave a partial snapshot behind (#695).
    func commitSnapshot(_ items: [HistoryItem], flushing entries: [WALEntry]) throws {
        let flushedIDs = Set(entries.map(\.id))
        let remaining = try loadWALEntries().filter { !flushedIDs.contains($0.id) }
        try writeSnapshot(items)
        try replaceWAL(with: remaining)
    }

    /// Replays and clears the WAL as one actor operation. Keeping the complete
    /// read/merge/write/clear sequence here prevents a concurrent append from
    /// being cleared without first being included in the snapshot.
    ///
    /// An unreadable WAL (I/O or permission failure) throws so the manager can
    /// refuse startup instead of treating it as empty history. A WAL whose
    /// content decodes to nothing at all is quarantined beside the live file
    /// and replay falls back to the snapshot — deliberate recovery, distinct
    /// from an unavailable store (#695).
    func replayWAL() throws -> [HistoryItem]? {
        guard FileManager.default.fileExists(atPath: walURL.path) else { return nil }
        try walHandle?.synchronize()
        let data = try Data(contentsOf: walURL)
        let decoded = Self.decodeWALContent(from: data, decoder: decoder)
        if decoded.isFullyUndecodable {
            try quarantineCorruptWAL()
            return nil
        }
        let walEntries = decoded.entries
        guard !walEntries.isEmpty else {
            try replaceWAL(with: [])
            return nil
        }

        log.info("Replaying \(walEntries.count) WAL entries")
        let currentItems = walEntries.applied(to: try loadSnapshot())

        try writeSnapshot(currentItems)
        try replaceWAL(with: [])
        log.info("WAL replay complete, cleared WAL file")
        return currentItems
    }

    func loadWALEntries() throws -> [WALEntry] {
        guard FileManager.default.fileExists(atPath: walURL.path) else { return [] }
        try walHandle?.synchronize()
        let data = try Data(contentsOf: walURL)
        return Self.decodeWALContent(from: data, decoder: decoder).entries
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

    /// Result of decoding raw WAL bytes: the recovered entries plus whether the
    /// file held real content of which nothing decoded (torn tails still count
    /// as partially decodable; this flag means the whole file is unusable).
    struct DecodedWALContent {
        let entries: [WALEntry]
        let isFullyUndecodable: Bool
    }

    static func decodeWALContent(from data: Data, decoder: JSONDecoder) -> DecodedWALContent {
        if let legacy = try? decoder.decode([WALEntry].self, from: data) {
            return DecodedWALContent(entries: legacy, isFullyUndecodable: false)
        }
        var entries: [WALEntry] = []
        var sawContent = false
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            sawContent = true
            if let entry = try? decoder.decode(WALEntry.self, from: Data(line)) {
                entries.append(entry)
            } else if let legacy = try? decoder.decode([WALEntry].self, from: Data(line)) {
                entries.append(contentsOf: legacy)
            }
        }
        return DecodedWALContent(
            entries: entries,
            isFullyUndecodable: sawContent && entries.isEmpty
        )
    }

    /// Moves an unusable WAL aside (never deletes it) so startup can proceed
    /// from the snapshot while the original bytes stay available for support.
    private func quarantineCorruptWAL() throws {
        try walHandle?.close()
        walHandle = nil
        let timestamp = Int(Date().timeIntervalSince1970)
        let quarantineURL = walURL
            .deletingLastPathComponent()
            .appendingPathComponent("history-wal.corrupt-\(timestamp).json", isDirectory: false)
        try FileManager.default.moveItem(at: walURL, to: quarantineURL)
        log.error(
            "Quarantined undecodable WAL as \(quarantineURL.lastPathComponent, privacy: .public)"
        )
    }
}
