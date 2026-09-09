import Foundation
import SpeakCore

enum MigrationPlanner {
    static func conflicts(current: MigrationSnapshot, incoming: MigrationSnapshot,
                          modes: [MigrationCategory: MigrationMode]) -> [MigrationConflict] {
        var result: [MigrationConflict] = []
        for category in incoming.manifest.categories where modes[category] == .merge {
            let currentRecords = current.records[category] ?? []
            for record in incoming.records[category] ?? []
                where record.kind != "history" && record.kind != "audio" {
                if let old = currentRecords.first(where: { $0.identity == record.identity }),
                   old.value != record.value {
                    result.append(.init(category: category, existing: old, imported: record))
                }
            }
        }
        return result
    }

    static func plan(current: MigrationSnapshot, incoming: MigrationSnapshot,
                     modes: [MigrationCategory: MigrationMode],
                     useImported: Set<String>) -> MigrationSnapshot {
        var output = current
        output.notices = incoming.notices
        output.files.merge(incoming.files) { _, new in new }
        for category in incoming.manifest.categories
            where modes[category] != .skip && modes[category] != nil {
            guard let imported = incoming.records[category] else {
                continue
            }
            let scope = incoming.manifest.scopes[category.rawValue] ?? MigrationScope()
            var records = current.records[category] ?? []
            // A damaged export must never turn a partial read into a destructive clear.
            let hasInvalidItems = incoming.notices.contains { $0.hasPrefix(category.title + ":")
                || $0.hasPrefix(category.title + ",") }
            if modes[category] == .replace && !hasInvalidItems {
                records.removeAll { record in
                    category == .history || category == .recordings
                        ? scope.contains(id: record.id, date: record.date) : true
                }
            }
            for record in imported {
                merge(record, into: &records, category: category, mode: modes[category] ?? .merge,
                      useImported: useImported)
            }
            if hasInvalidItems && modes[category] == .replace {
                output.notices
                    .append(
                        "\(category.title): preserved existing items because this category contained invalid items."
                    )
            }
            output.notices
                .append(
                    "\(category.title): processed \(imported.count) imported items; "
                        + "\(records.count) retained after \(modes[category]?.rawValue ?? "merge")."
                )
            output.records[category] = records
        }
        return output
    }

    private static func merge(_ incoming: MigrationRecord, into records: inout [MigrationRecord],
                              category: MigrationCategory, mode: MigrationMode, useImported: Set<String>) {
        var record = incoming
        if let index = records.firstIndex(where: { $0.identity == record.identity }) {
            let old = records[index]
            if equivalent(old, record) {
                return
            }
            if record.kind == "history" {
                let oldText = hasText(old)
                let newText = hasText(record)
                if !oldText && newText {
                    records[index] = record; return
                }
                if oldText && !newText {
                    return
                }
            }
            if record.kind == "history" || record.kind == "audio" {
                record.id = MigrationCoding.variantID(id: record.id,
                                                      revision: record.revision ?? MigrationCoding
                                                          .digest((try? MigrationCoding.encoder
                                                                  .encode(record.value)) ?? Data()))
                if records
                    .contains(where: { $0.identity == record.identity && equivalent($0, record) }) {
                    return }
                records.append(record)
            } else if mode == .replace || useImported
                .contains(category.rawValue + ":" + record.identity) {
                records[index] = record
            }
        } else {
            records.append(record)
        }
    }

    private static func hasText(_ record: MigrationRecord) -> Bool {
        guard let object = record.value.value as? [String: Any] else {
            return true
        }
        return object["rawTranscription"] is String || object["postProcessedTranscription"] is String
    }

    private static func equivalent(_ lhs: MigrationRecord, _ rhs: MigrationRecord) -> Bool {
        if lhs.kind == "audio" {
            return lhs.digest == rhs.digest
        }
        if lhs.kind == "history", var left = lhs.value.value as? [String: Any],
           var right = rhs.value.value as? [String: Any] {
            for key in ["id", "updatedAt"] { left.removeValue(forKey: key); right.removeValue(forKey: key) }
            return (try? AnyCodable(left)) == (try? AnyCodable(right))
        }
        return lhs.value == rhs.value
    }
}

extension HistoryItem {
    func migrationValue(audioOnly: Bool = false, audioURL: URL? = nil,
                        id: String? = nil) throws -> AnyCodable {
        var object = try MigrationCoding.value(self).value as? [String: Any] ?? [:]
        object.removeValue(forKey: "audioFileURL")
        // Diagnostic request bodies/headers are not portable user content and may contain credentials.
        object["networkExchanges"] = []
        object.removeValue(forKey: "diagnosticContext")
        if let audioURL {
            object["audioFileURL"] = audioURL.absoluteString
        }
        if let id {
            object["id"] = id
        }
        if audioOnly {
            object.removeValue(forKey: "rawTranscription")
            object.removeValue(forKey: "postProcessedTranscription")
            object.removeValue(forKey: "postProcessingPrompt")
            object.removeValue(forKey: "personalCorrections")
            object["events"] = []
            object["errors"] = []
        }
        return try AnyCodable(object)
    }
}
