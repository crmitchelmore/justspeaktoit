import Foundation
import SpeakCore

enum MigrationPlanner {
    static func conflicts(current: MigrationSnapshot, incoming: MigrationSnapshot,
                          modes: [MigrationCategory: MigrationMode]) -> [MigrationConflict] {
        DataMigrationPlanner.conflicts(current: current, incoming: incoming, modes: modes).map {
            MigrationConflict(category: $0.category, existing: $0.existing, imported: $0.imported)
        }
    }

    static func plan(current: MigrationSnapshot, incoming: MigrationSnapshot,
                     modes: [MigrationCategory: MigrationMode],
                     useImported: Set<String>) throws -> MigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: modes, useImported: useImported,
            digest: MigrationCoding.digest
        )
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
