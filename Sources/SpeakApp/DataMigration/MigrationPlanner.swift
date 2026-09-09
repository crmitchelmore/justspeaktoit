import Foundation
import SpeakCore

enum MigrationPlanner {
    static func conflicts(current: MigrationSnapshot, incoming: MigrationSnapshot,
                          modes: [MigrationCategory: MigrationMode]) -> [MigrationConflict] {
        var result: [MigrationConflict] = []
        for category in incoming.manifest.categories where modes[category] == .merge {
            let currentRecords = Dictionary((current.records[category] ?? []).map { ($0.identity, $0) },
                                            uniquingKeysWith: { _, last in last })
            for record in incoming.records[category] ?? []
                where record.kind != "history" && record.kind != "audio" {
                if let old = currentRecords[record.identity],
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
            var indexes = Dictionary(records.enumerated().map { ($0.element.identity, $0.offset) },
                                     uniquingKeysWith: { _, last in last })
            for record in imported {
                merge(record, into: &records, indexes: &indexes,
                      overwrite: modes[category] == .replace
                        || useImported.contains(category.rawValue + ":" + record.identity))
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
        reconnectVariants(current: current, incoming: incoming, modes: modes, output: &output)
        return output
    }

    private static func reconnectVariants(current: MigrationSnapshot, incoming: MigrationSnapshot,
                                          modes: [MigrationCategory: MigrationMode],
                                          output: inout MigrationSnapshot) {
        for category in [MigrationCategory.history, .recordings] where modes[category] == .merge {
            let counterpart: MigrationCategory = category == .history ? .recordings : .history
            let counterpartIDs = Set(output.records[counterpart, default: []].map(\.id))
            var ownIDs = Set(output.records[category, default: []].map(\.id))
            let currentIDs = Set(current.records[category, default: []].map(\.identity))
            var removeIDs = Set<String>()
            for original in incoming.records[category] ?? []
                where original.kind == "history" || original.kind == "audio" {
                guard let revision = original.revision else { continue }
                let variantID = MigrationCoding.variantID(id: original.id, revision: revision)
                guard counterpartIDs.contains(variantID) else { continue }
                if ownIDs.insert(variantID).inserted {
                    var linked = original
                    linked.id = variantID
                    output.records[category, default: []].append(linked)
                }
                // Do not attach a newly imported counterpart to the older conflicting session.
                if !currentIDs.contains(original.identity) {
                    removeIDs.insert(original.identity)
                }
            }
            output.records[category]?.removeAll { removeIDs.contains($0.identity) }
        }
    }

    private static func merge(_ incoming: MigrationRecord, into records: inout [MigrationRecord],
                              indexes: inout [String: Int],
                              overwrite: Bool) {
        var record = incoming
        if let index = indexes[record.identity] {
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
                if let variant = indexes[record.identity] {
                    if equivalent(records[variant], record) { return }
                    record.id = MigrationCoding.variantID(id: record.id, revision: MigrationCoding
                        .digest((try? MigrationCoding.encoder.encode(record.value)) ?? Data()))
                    if let existing = indexes[record.identity], equivalent(records[existing], record) { return }
                }
                indexes[record.identity] = records.count
                records.append(record)
            } else if overwrite {
                records[index] = record
            }
        } else {
            indexes[record.identity] = records.count
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
