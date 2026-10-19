import Foundation
import SpeakCore

/// Previews and applies a Mac-compatible ZIP backup to desktop History text and
/// dictation profiles. Nothing is written until `apply` runs with an explicit
/// choice; every other category is reported as preserved but not applied.
public enum DesktopMigrationRestore {
    /// History always merges: replacing it would need permanent deletion
    /// tombstones that cannot be rolled back. Replace changes profiles only.
    public enum Choice: Int, Equatable, Sendable {
        case merge = 1
        case replace = 2
    }

    public struct Targets: Sendable {
        let history: DesktopRecordingStore
        let profiles: DesktopDictationProfileStore
        let digests: LocalModelDigestProvider

        public init(
            history: DesktopRecordingStore, profiles: DesktopDictationProfileStore, digests: LocalModelDigestProvider
        ) {
            self.history = history
            self.profiles = profiles
            self.digests = digests
        }
    }

    public struct Changes: Equatable, Sendable {
        public let existing: Int
        public let added: Int
        public let updated: Int
        public let removed: Int
        public let retained: Int
        /// Replace adopts the backup's profile order, which sets precedence.
        public let reordered: Bool

        public var isEmpty: Bool { added == 0 && updated == 0 && removed == 0 && !reordered }
    }

    public struct Row: Equatable, Sendable {
        public let category: DataMigrationCategory
        /// Nil means the imported category could not be read; existing items are kept.
        public let merge: Changes?
        public let replace: Changes?
        /// Items present on both sides with different values. Merge keeps this
        /// device's version; Replace uses the backup's version.
        public let conflicts: Int
        public let invalid: Int
        /// Replace kept existing items because the imported category was damaged.
        public let preservedOnReplace: Bool
    }

    public struct Preview: Equatable, Sendable {
        public let rows: [Row]
        /// Declared categories this host keeps unapplied.
        public let notApplied: [DataMigrationCategory]
        /// Item-level reasons an otherwise valid item is not written.
        public let skipped: [String]
        public let noticeCount: Int

        public func changes(_ choice: Choice) -> Bool {
            rows.contains { row in
                (choice == .merge ? row.merge : row.replace).map { !$0.isEmpty } ?? false
            }
        }

        /// True when Replace would write something different from Merge.
        public var offersReplace: Bool { rows.contains { $0.merge != $0.replace } }
    }

    public struct Plan: Sendable {
        public let preview: Preview
        let incoming: DataMigrationSnapshot
        let baseline: Baseline
    }

    struct Baseline: Equatable, Sendable {
        let history: [DataMigrationRecord]
        let profiles: [DataMigrationRecord]
        /// Raw bytes, or nil when profiles.json is absent.
        let profileDocument: Data?
    }

    public enum Preparation: Sendable {
        case ready(Plan)
        case cancelled
        case failed(String)
    }

    public struct Applied: Sendable {
        public let choice: Choice
        public let history: [DesktopRecordingStore.Record]
        public let profilesChanged: Bool
        public let preview: Preview
    }

    public enum Outcome: Sendable {
        case applied(Applied)
        /// Application data changed after the preview; nothing was written.
        case stale(String)
        /// Cancelled before or during apply. `restored` is false only when
        /// a rollback step itself failed and the message names it.
        case cancelled(restored: Bool, String)
        case failed(restored: Bool, String)
    }

    /// Reads, validates and previews without writing application data.
    /// Run on an owned cancellable off-actor worker, not a settings queue.
    public static func prepare(
        _ source: URL, reader: DesktopMigrationInspection.Reader, targets: Targets
    ) async -> Preparation {
        var staging: URL?
        var outcome: Preparation
        do {
            try Task.checkCancellation()
            try DesktopMigrationStaging.requireLocalFile(source)
            guard !source.hasDirectoryPath else {
                throw DataMigrationError.invalid("Choose a ZIP file, not a directory.")
            }
            let snapshot = try reader.read(source)
            guard let directory = snapshot.directory else {
                throw DataMigrationError.invalid("The archive reader returned no owned private staging directory.")
            }
            let owned = try DesktopMigrationStaging.directory(directory, prefix: "migration-")
            guard owned.standardizedFileURL.pathComponents
                != source.deletingLastPathComponent().standardizedFileURL.pathComponents else {
                throw DataMigrationError.invalid("Restore refuses to remove the source archive's directory.")
            }
            staging = owned
            outcome = .ready(try await plan(snapshot, targets: targets))
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if let staging {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                let detail = "Private restore staging could not be removed: \(error.localizedDescription)"
                if case let .failed(message) = outcome {
                    outcome = .failed(message + " " + detail)
                } else {
                    outcome = .failed(detail)
                }
            }
        }
        if case .ready = outcome, Task.isCancelled { return .cancelled }
        return outcome
    }

    /// Validates an already-read snapshot and previews both choices.
    static func plan(_ snapshot: DataMigrationSnapshot, targets: Targets) async throws -> Plan {
        let checked = try DataMigrationRecordValidation.validate(
            snapshot, checkCancellation: { try Task.checkCancellation() }, recordValidator: validateRecord
        )
        var incoming = DataMigrationSnapshot(
            manifest: checked.manifest,
            records: checked.records.filter { applied.contains($0.key) },
            notices: checked.notices
        )
        incoming.manifest.categories = checked.manifest.categories.filter(applied.contains)
        for category in applied {
            try requireUnique(incoming.records[category] ?? [], category: category)
        }
        let baseline = try await currentBaseline(targets)
        let guards = try await targets.history.migrationRestoreGuards()
        let merge = try compute(incoming, baseline: baseline, choice: .merge, guards: guards, digests: targets.digests)
        let replace = try compute(
            incoming, baseline: baseline, choice: .replace, guards: guards, digests: targets.digests
        )
        let invalid = Dictionary(grouping: checked.notices.filter { $0.hasSuffix(invalidSuffix) }) { notice in
            applied.first { notice.hasPrefix($0.title + ",") }
        }
        let conflicts = DataMigrationPlanner.conflicts(
            current: baselineSnapshot(baseline), incoming: incoming, modes: [.profiles: .merge]
        )
        let rows = DataMigrationCategory.allCases.filter {
            applied.contains($0) && snapshot.manifest.categories.contains($0)
        }.map { category in
            Row(
                category: category, merge: merge.changes[category], replace: replace.changes[category],
                conflicts: conflicts.filter { $0.category == category }.count,
                invalid: invalid[category]?.count ?? 0,
                preservedOnReplace: category == .profiles && incoming.records[category] != nil
                    && hasDamage(incoming, category: category)
            )
        }
        try Task.checkCancellation()
        let preview = Preview(
            rows: rows,
            notApplied: DataMigrationCategory.allCases.filter {
                !applied.contains($0) && snapshot.manifest.categories.contains($0)
            },
            skipped: Array(Set(merge.skipped + replace.skipped)).sorted(),
            noticeCount: snapshot.notices.count
        )
        return Plan(preview: preview, incoming: incoming, baseline: baseline)
    }

    /// Categories this host can write and roll back. Credentials are never
    /// installed silently; other categories stay preserved but not applied.
    static let applied: Set<DataMigrationCategory> = [.history, .profiles]
    static let invalidSuffix = ": skipped invalid or unsupported item."

    static func validateRecord(_ record: DataMigrationRecord, category: DataMigrationCategory) throws {
        switch category {
        case .history:
            _ = try DesktopMigrationHistory.record(record, category: category)
        case .profiles:
            try DataMigrationProfileCatalog.validate(record, category: category)
        default:
            break
        }
    }

    static func hasDamage(_ snapshot: DataMigrationSnapshot, category: DataMigrationCategory) -> Bool {
        snapshot.notices.contains { $0.hasPrefix(category.title + ":") || $0.hasPrefix(category.title + ",") }
    }

    private static func requireUnique(_ records: [DataMigrationRecord], category: DataMigrationCategory) throws {
        var identities = Set<String>()
        for record in records {
            try Task.checkCancellation()
            // History identities are UUIDs, so spelling must not hide a duplicate.
            let identity = category == .history ? record.identity.uppercased() : record.identity
            guard identities.insert(identity).inserted else {
                throw DataMigrationError.invalid("\(category.title): duplicate identities prevent restore.")
            }
        }
    }
}
