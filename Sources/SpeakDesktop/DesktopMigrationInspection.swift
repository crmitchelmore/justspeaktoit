import Foundation
import SpeakCore

/// Read-only archive inspection, not approval or application of imported values.
public enum DesktopMigrationInspection {
    public struct Reader: Sendable {
        let read: @Sendable (URL) throws -> DataMigrationSnapshot

        /// Returns a snapshot in a newly created private migration-<UUID>
        /// directory owned exclusively by this read, including History-only ZIPs.
        public init(read: @escaping @Sendable (URL) throws -> DataMigrationSnapshot) {
            self.read = read
        }
    }

    public struct Category: Equatable, Sendable {
        public let category: DataMigrationCategory
        /// Nil means the declared category could not be read, never zero.
        public let items: Int?
    }

    public struct Report: Equatable, Sendable {
        public let categories: [Category]
        public let noticeCount: Int
        public let historyChecks: [Category]
        public let invalidHistoryItems: Int

        public var text: String {
            let rows = categories.map { row in
                let count = row.items.map { $0 == 1 ? "1 item read" : "\($0) items read" } ?? "could not be read"
                return "\(row.category.title): \(count)"
            }
            var sections = [
                "No application data was changed.",
                rows.isEmpty ? "No categories are declared in this backup." : rows.joined(separator: "\n")
            ]
            if noticeCount > 0 {
                sections.append("\(noticeCount) archive notices: some data may be missing or damaged.")
            }
            if !historyChecks.isEmpty {
                let checks = historyChecks.map { row in
                    guard let count = row.items else { return "\(row.category.title): could not be validated" }
                    return "\(row.category.title): \(count) structurally valid"
                }
                sections.append(checks.joined(separator: "\n"))
                if invalidHistoryItems > 0 {
                    sections.append("\(invalidHistoryItems) History/audio items failed record validation.")
                }
            }
            sections.append(
                "Inspection checks the archive envelope and extracted audio checksums. "
                    + "History/audio record structure is checked; other record values are not validated. "
                    + "Record values are not yet approved for import. Import/apply is not available here."
            )
            if categories.contains(where: { $0.category == .credentials }) {
                sections.append("This ZIP contains credentials. Their values are not displayed or installed.")
            }
            return sections.joined(separator: "\n\n")
        }

        init(_ snapshot: DataMigrationSnapshot, checked: DataMigrationSnapshot) {
            categories = DataMigrationCategory.allCases.filter(snapshot.manifest.categories.contains).map {
                .init(category: $0, items: snapshot.records[$0]?.count)
            }
            noticeCount = snapshot.notices.count
            historyChecks = [.history, .recordings].filter(snapshot.manifest.categories.contains).map {
                .init(category: $0, items: checked.records[$0]?.count)
            }
            invalidHistoryItems = historyChecks.reduce(0) { count, row in
                guard let read = snapshot.records[row.category]?.count, let valid = row.items else { return count }
                return count + read - valid
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case inspected(Report)
        case cancelled
        case failed(String)
    }

    /// Run on an owned cancellable off-actor worker, not a settings queue.
    public static func inspect(_ source: URL, reader: Reader) async -> Outcome {
        var staging: URL?
        var outcome: Outcome
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
                throw DataMigrationError.invalid("Inspection refuses to remove the source archive's directory.")
            }
            staging = owned
            try Task.checkCancellation()
            let checked = try DataMigrationRecordValidation.validate(
                snapshot, checkCancellation: { try Task.checkCancellation() },
                recordValidator: { record, category in
                    if category == .history || category == .recordings {
                        _ = try DesktopMigrationHistory.record(record, category: category)
                    }
                }
            )
            outcome = .inspected(Report(snapshot, checked: checked))
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if let staging {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                let detail = "Private inspection staging could not be removed: \(error.localizedDescription)"
                if case let .failed(message) = outcome {
                    outcome = .failed(message + " " + detail)
                } else {
                    outcome = .failed(detail)
                }
            }
        }
        if case .inspected = outcome, Task.isCancelled { return .cancelled }
        return outcome
    }
}
