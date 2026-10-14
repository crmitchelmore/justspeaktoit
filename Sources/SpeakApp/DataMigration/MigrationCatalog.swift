import Foundation
import SpeakCore

/// Explicitly owned stores only: never copy arbitrary defaults, sync identities,
/// installation markers, caches, or executable code from an archive.
@MainActor
enum MigrationCatalog {
    struct Collection {
        let kind: String
        let category: MigrationCategory
        let defaultsKey: String?
        let path: String?
    }
    static let collections: [Collection] = [
        .init(
            kind: "modelReference",
            category: .models,
            defaultsKey: nil,
            path: "LocalModels/migration-model-references.json"
        ),
        .init(kind: DataMigrationProfileCatalog.kind, category: DataMigrationProfileCatalog.category,
              defaultsKey: DataMigrationProfileCatalog.defaultsKey, path: nil),
        .init(
            kind: "pronunciation",
            category: .vocabulary,
            defaultsKey: "pronunciationDictionary",
            path: nil
        ),
        .init(kind: "lexicon", category: .vocabulary, defaultsKey: nil, path: "PersonalLexicon/lexicon.json"),
        .init(
            kind: "correction",
            category: .vocabulary,
            defaultsKey: nil,
            path: "AutoCorrections/candidates.json"
        ),
        .init(kind: "ttsUsage", category: .history, defaultsKey: "ttsUsageHistory", path: nil),
        .init(kind: "whisperModel", category: .models, defaultsKey: nil,
              path: "LocalModels/imported-hugging-face-models.json"),
        .init(kind: "streamingModel", category: .models, defaultsKey: nil,
              path: "LocalModels/streaming-model-sources.json"),
        .init(kind: "llmModel", category: .models, defaultsKey: nil,
              path: "LocalModels/LocalPostProcessing/imported-hugging-face-gguf-models.json")
    ]
    static let vocabularyKeys = DataMigrationPreferenceCatalog.keys(in: .vocabulary)
    static let connectionKeys = DataMigrationPreferenceCatalog.keys(in: .connections)
    static let credentialDefaults = DataMigrationPreferenceCatalog.keys(in: .credentials)
    static var settingKeys: Set<String> {
        DataMigrationPreferenceCatalog.keys(in: .settings)
    }
    static func category(for key: String) -> MigrationCategory? {
        DataMigrationPreferenceCatalog.category(for: key)
    }
    static func defaultsRecord(key: String, value: Any) throws -> MigrationRecord {
        let payload: AnyCodable
        let kind: String
        if let data = value as? Data {
            payload = try MigrationCoding.decoder.decode(AnyCodable.self, from: data)
            kind = "jsonDefault"
        } else {
            payload = try AnyCodable(value)
            kind = "default"
        }
        return MigrationRecord(id: key, kind: kind, value: payload)
    }
    static func collectionRecords(_ collection: Collection, data: Data) throws -> [MigrationRecord] {
        try DataMigrationCollectionRecords.records(data: data, kind: collection.kind, digest: MigrationCoding.digest)
    }
    static func validate(_ record: MigrationRecord, category: MigrationCategory) throws {
        guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.id.count < 1024 else {
            throw MigrationError.invalid("Invalid identifier")
        }
        switch record.kind {
        case "default", "jsonDefault":
            guard self.category(for: record.id) == category
            else {
                throw MigrationError.invalid("Unknown setting")
            }
            try MigrationPreferenceSchema.validate(record)
        case "secret":
            guard category == .credentials, record.value.value is String
            else {
                throw MigrationError.invalid("Invalid credential")
            }
        case "history", "audio": try validateHistory(record, category: category)
        default: try validateCollection(record, category: category)
        }
    }
    private static func validateHistory(_ record: MigrationRecord, category: MigrationCategory) throws {
        _ = try DataMigrationHistorySchema.validate(record, category: category)
    }
    private static func validateCollection(_ record: MigrationRecord, category: MigrationCategory) throws {
        guard let collection = collections.first(where: { $0.kind == record.kind }),
              collection.category == category else {
            throw MigrationError.invalid("Unknown item type")
        }
        if let object = record.value.value as? [String: Any], let id = object["id"] as? String,
           id != record.id {
            throw MigrationError.invalid("Mismatched item identifier")
        }
        if category == .models {
            try validateModel(record); return
        }
        switch record.kind {
        case DataMigrationProfileCatalog.kind: try DataMigrationProfileCatalog.validate(record, category: category)
        case "pronunciation":
            _ = try JSONDecoder().decode(PronunciationEntry.self, from: JSONEncoder().encode(record.value))
        case "lexicon": _ = try MigrationCoding.decode(PersonalLexiconRule.self, record.value)
        case "correction": _ = try MigrationCoding.decode(AutoCorrectionCandidate.self, record.value)
        case "ttsUsage": _ = try JSONDecoder().decode(
                TTSUsageRecord.self,
                from: JSONEncoder().encode(record.value)
            )
        default: throw MigrationError.invalid("Unknown collection")
        }
    }
    private static func validateModel(_ record: MigrationRecord) throws {
        guard record.id.hasPrefix("local/"), !record.id.contains("..") else {
            throw MigrationError.invalid("Invalid model identifier")
        }
        switch record.kind {
        case "modelReference":
            let reference = try MigrationCoding.decode(MigrationModelReference.self, record.value)
            guard ["whisper", "fluidAudio", "llm", "streaming"].contains(reference.family),
                  reference.id == record.id else {
                throw MigrationError.invalid("Invalid model reference")
            }
        case "whisperModel":
            let model = try MigrationCoding.decode(ImportedModelRecord.self, record.value)
            try validateSource(model.modelRepo ?? "argmaxinc/whisperkit-coreml", filename: model.modelName)
        case "streamingModel": try validateStreamingModel(record)
        case "llmModel":
            #if !APP_STORE
                let model = try MigrationCoding.decode(LocalPostProcessingModel.self, record.value)
                try validateSource(model.repoID, filename: model.filename)
            #else
                throw MigrationError.invalid("External model runtimes are unavailable in this build")
            #endif
        default: throw MigrationError.invalid("Unknown model type")
        }
    }
    private static func validateStreamingModel(_ record: MigrationRecord) throws {
        #if !APP_STORE
            let model = try MigrationCoding.decode(LocalStreamingModelSource.self, record.value)
            try validateSource(model.repoID, filename: model.modelName)
            if let url = model.archiveURL,
               url.scheme != "https" {
                throw MigrationError.invalid("Invalid model source")
            }
        #else
            throw MigrationError.invalid("External streaming runtimes are unavailable in this build")
        #endif
    }
    private static func validateSource(_ source: String, filename: String) throws {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !filename.isEmpty, !filename.contains(".."), !filename.hasPrefix("/"),
              !filename.contains("\\"), !source.contains(":") else {
            throw MigrationError.invalid("Invalid model source")
        }
    }
}
