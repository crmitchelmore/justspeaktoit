import Foundation
import SpeakCore

/// A History write failed part-way. Every entry it touched was restored unless
/// `rollbackFailures` names it.
public struct DesktopMigrationRestoreWriteError: LocalizedError {
    public let underlying: Error
    public let rollbackFailures: [String]

    public var errorDescription: String? {
        guard !rollbackFailures.isEmpty else { return self.underlying.localizedDescription }
        return self.underlying.localizedDescription + " Rollback could not restore: "
            + self.rollbackFailures.joined(separator: "; ")
    }
}

extension DesktopRecordingStore {
    struct MigrationRestoreGuards: Sendable {
        /// Every metadata basename, including hidden deleted ones, by UUID.
        let existing: Set<UUID>
        let synced: Set<UUID>
        let deleted: Set<UUID>
    }

    func migrationRestoreGuards() throws -> MigrationRestoreGuards {
        let existing = Set(try metadataFiles().compactMap(Self.recordID(ofMetadataFile:)))
        let synced = Set(try records().filter(\.isSyncedCopy).map(\.id))
        return MigrationRestoreGuards(existing: existing, synced: synced, deleted: Set(deletionLedger.intents.keys))
    }

    /// Writes restored History, rolling every touched file back to its prior
    /// bytes (or removing a file it added) when a write or checkpoint fails.
    /// Records are never deleted through the tombstone ledger here.
    func applyMigrationRestore(
        _ writes: [DesktopMigrationRestore.HistoryWrite],
        expectedHistory: [DataMigrationRecord], digests: LocalModelDigestProvider,
        checkpoint: @Sendable (DesktopMigrationRestore.Step) throws -> Void
    ) throws -> [Record] {
        let files = try migrationRestoreFiles(expectedHistory: expectedHistory, digests: digests)
        // swiftlint:disable:next large_tuple
        var staged: [(url: URL, prior: Data?, record: Record)] = []
        for write in writes {
            try Task.checkCancellation()
            try requireRetained(write.id)
            guard (files[write.id] != nil) == write.replacing else {
                throw DataMigrationError.invalid("History changed after the preview, so nothing was restored.")
            }
            let url = files[write.id] ?? directory.appendingPathComponent(write.id.uuidString + ".json")
            var existing: Record?
            if write.replacing {
                let current = try loadRecord(at: url)
                guard !current.isSyncedCopy else {
                    throw DataMigrationError.invalid("History changed after the preview, so nothing was restored.")
                }
                existing = current
            }
            let prior = write.replacing ? try Data(contentsOf: url) : nil
            staged.append((url, prior, try DesktopMigrationRestore.nativeHistory(write, existing: existing)))
        }
        var attempted = 0
        do {
            for (index, entry) in staged.enumerated() {
                try checkpoint(.history(index))
                attempted = index + 1
                try writeMigrationRecord(entry.record, to: entry.url)
            }
            try checkpoint(.finished)
        } catch {
            var failures: [String] = []
            for entry in staged.prefix(attempted).reversed() {
                do {
                    if let prior = entry.prior {
                        try prior.write(to: entry.url, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: entry.url.path) {
                        try FileManager.default.removeItem(at: entry.url)
                    }
                } catch {
                    failures.append("History item \(entry.url.lastPathComponent) (\(error.localizedDescription))")
                }
            }
            throw DesktopMigrationRestoreWriteError(underlying: error, rollbackFailures: failures)
        }
        return staged.map(\.record)
    }

    private func migrationRestoreFiles(
        expectedHistory: [DataMigrationRecord], digests: LocalModelDigestProvider
    ) throws -> [UUID: URL] {
        // No actor suspension is allowed between this recheck and the writes.
        let snapshot = try migrationSnapshot(categories: [.history], digests: digests)
        let current = snapshot.records[.history] ?? []
        guard current.sorted(by: { $0.id < $1.id }) == expectedHistory.sorted(by: { $0.id < $1.id }) else {
            throw DesktopMigrationRestore.StaleHistory()
        }
        var files: [UUID: URL] = [:]
        for url in try metadataFiles() {
            guard let id = Self.recordID(ofMetadataFile: url) else { continue }
            guard files.updateValue(url, forKey: id) == nil else {
                throw DataMigrationError.invalid("History: two files claim one item, so nothing was restored.")
            }
        }
        return files
    }

    private func writeMigrationRecord(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
