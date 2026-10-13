import Foundation

public struct DataMigrationConflict: Identifiable, Sendable {
    public let category: DataMigrationCategory
    public let existing: DataMigrationRecord
    public let imported: DataMigrationRecord

    public var id: String { category.rawValue + ":" + imported.identity }
    public var title: String { imported.id }

    public init(category: DataMigrationCategory, existing: DataMigrationRecord, imported: DataMigrationRecord) {
        self.category = category
        self.existing = existing
        self.imported = imported
    }
}

/// Plans validated snapshots; hosts retain ownership of staged files and apply transactions.
public enum DataMigrationPlanner {
    public static func conflicts(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot,
        modes: [DataMigrationCategory: DataMigrationMode]
    ) -> [DataMigrationConflict] {
        var result: [DataMigrationConflict] = []
        for category in incoming.manifest.categories where modes[category] == .merge {
            let currentRecords = Dictionary(
                (current.records[category] ?? []).map { ($0.identity, $0) }, uniquingKeysWith: { _, last in last }
            )
            for record in incoming.records[category] ?? [] where record.kind != "history" && record.kind != "audio" {
                if let old = currentRecords[record.identity], old.value != record.value {
                    result.append(.init(category: category, existing: old, imported: record))
                }
            }
        }
        return result
    }

    public static func plan(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot,
        modes: [DataMigrationCategory: DataMigrationMode], useImported: Set<String>,
        digest: (Data) throws -> String
    ) throws -> DataMigrationSnapshot {
        try Task.checkCancellation()
        var output = current
        output.notices = incoming.notices
        output.files.merge(incoming.files) { _, new in new }
        for category in incoming.manifest.categories where modes[category] != .skip && modes[category] != nil {
            try Task.checkCancellation()
            guard let imported = incoming.records[category] else { continue }
            let scope = incoming.manifest.scopes[category.rawValue] ?? DataMigrationScope()
            var records = current.records[category] ?? []
            // A damaged export must never turn a partial read into a destructive clear.
            let hasInvalidItems = incoming.notices.contains {
                $0.hasPrefix(category.title + ":") || $0.hasPrefix(category.title + ",")
            }
            if modes[category] == .replace && !hasInvalidItems {
                records.removeAll { record in
                    category == .history || category == .recordings
                        ? scope.contains(id: record.id, date: record.date) : true
                }
            }
            var indexes = Dictionary(
                records.enumerated().map { ($0.element.identity, $0.offset) }, uniquingKeysWith: { _, last in last }
            )
            for record in imported {
                try Task.checkCancellation()
                try merge(
                    record, into: &records, indexes: &indexes,
                    overwrite: modes[category] == .replace
                        || useImported.contains(category.rawValue + ":" + record.identity),
                    digest: digest
                )
            }
            if hasInvalidItems && modes[category] == .replace {
                output.notices.append(
                    "\(category.title): preserved existing items because this category contained invalid items."
                )
            }
            output.notices.append(
                "\(category.title): processed \(imported.count) imported items; "
                    + "\(records.count) retained after \(modes[category]?.rawValue ?? "merge")."
            )
            output.records[category] = records
        }
        try reconnectVariants(current: current, incoming: incoming, modes: modes, output: &output, digest: digest)
        try Task.checkCancellation()
        return output
    }

    private static func reconnectVariants(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot,
        modes: [DataMigrationCategory: DataMigrationMode], output: inout DataMigrationSnapshot,
        digest: (Data) throws -> String
    ) throws {
        for category in [DataMigrationCategory.history, .recordings] where modes[category] == .merge {
            try Task.checkCancellation()
            let counterpart: DataMigrationCategory = category == .history ? .recordings : .history
            let counterpartIDs = Set(output.records[counterpart, default: []].map(\.id))
            var ownIDs = Set(output.records[category, default: []].map(\.id))
            let currentIDs = Set(current.records[category, default: []].map(\.identity))
            var removeIDs = Set<String>()
            for original in incoming.records[category] ?? []
                where original.kind == "history" || original.kind == "audio" {
                try Task.checkCancellation()
                guard let revision = original.revision else { continue }
                let identifier = try variantID(id: original.id, revision: revision, digest: digest)
                guard counterpartIDs.contains(identifier) else { continue }
                if ownIDs.insert(identifier).inserted {
                    var linked = original
                    linked.id = identifier
                    output.records[category, default: []].append(linked)
                }
                // Do not attach a newly imported counterpart to the older conflicting session.
                if !currentIDs.contains(original.identity) { removeIDs.insert(original.identity) }
            }
            output.records[category]?.removeAll { removeIDs.contains($0.identity) }
        }
    }

    private static func merge(
        _ incoming: DataMigrationRecord, into records: inout [DataMigrationRecord],
        indexes: inout [String: Int], overwrite: Bool, digest: (Data) throws -> String
    ) throws {
        var record = incoming
        guard let index = indexes[record.identity] else {
            indexes[record.identity] = records.count
            records.append(record)
            return
        }
        let old = records[index]
        if equivalent(old, record) { return }
        if let preferIncoming = historyPreference(incoming: record, existing: old) {
            if preferIncoming { records[index] = record }
            return
        }
        guard record.kind == "history" || record.kind == "audio" else {
            if overwrite { records[index] = record }
            return
        }
        let revision: String
        if let supplied = record.revision {
            revision = supplied
        } else {
            revision = try valueDigest(record.value, digest: digest)
        }
        record.id = try variantID(id: record.id, revision: revision, digest: digest)
        if let variant = indexes[record.identity] {
            if equivalent(records[variant], record) { return }
            record.id = try variantID(
                id: record.id, revision: valueDigest(record.value, digest: digest), digest: digest
            )
            if let existing = indexes[record.identity], equivalent(records[existing], record) { return }
        }
        indexes[record.identity] = records.count
        records.append(record)
    }

    private static func hasText(_ record: DataMigrationRecord) -> Bool {
        guard let object = record.value.value as? [String: Any] else { return true }
        return object["rawTranscription"] is String || object["postProcessedTranscription"] is String
    }

    private static func historyPreference(incoming: DataMigrationRecord, existing: DataMigrationRecord) -> Bool? {
        guard incoming.kind == "history" else { return nil }
        let oldText = hasText(existing)
        let newText = hasText(incoming)
        guard oldText != newText else { return nil }
        return newText
    }

    private static func equivalent(_ lhs: DataMigrationRecord, _ rhs: DataMigrationRecord) -> Bool {
        if lhs.kind == "audio" { return lhs.digest == rhs.digest }
        if lhs.kind == "history", var left = lhs.value.value as? [String: Any],
           var right = rhs.value.value as? [String: Any] {
            for key in ["id", "updatedAt"] {
                left.removeValue(forKey: key)
                right.removeValue(forKey: key)
            }
            return (try? AnyCodable(left)) == (try? AnyCodable(right))
        }
        return lhs.value == rhs.value
    }

    private static func valueDigest(_ value: AnyCodable, digest: (Data) throws -> String) throws -> String {
        try checkedDigest(DataMigrationCoding.encoder.encode(value), digest: digest)
    }

    private static func variantID(id: String, revision: String, digest: (Data) throws -> String) throws -> String {
        let hex = Array(try checkedDigest(Data((id + ":" + revision).utf8), digest: digest).prefix(32))
        return [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-").uppercased()
    }

    private static func checkedDigest(_ data: Data, digest: (Data) throws -> String) throws -> String {
        let result = try digest(data)
        guard result.utf8.count == 64,
              result.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DataMigrationError.invalid("The migration SHA-256 provider returned an invalid digest.")
        }
        return result
    }
}
