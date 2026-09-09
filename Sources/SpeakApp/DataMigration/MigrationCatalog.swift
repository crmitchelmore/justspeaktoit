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
        .init(kind: "profile", category: .profiles, defaultsKey: "dictationProfiles", path: nil),
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
    static let vocabularyKeys: Set<String> = [
        "transcriptionKeywords", "assemblyAIKeyterms", "recoveredTranscriptionKeywords",
        "assemblyAIIgnoredPronunciationTerms", "ttsPronunciationDictionary"
    ]
    static let connectionKeys: Set<String> = ["enableSendToMac", "enableAutomationServer"]
    static let credentialDefaults: Set<String> = ["speakTransportPairingCode", "speakTransportPairedDevices"]
    static var settingKeys: Set<String> {
        Set(AppSettings.DefaultsKey.allCases.map(\.rawValue))
            .subtracting([
                "trackedKeyIdentifiers",
                "transcriptionKeywordsLastReconciled",
                "ttsPronunciationDictionary"
            ])
            .subtracting(vocabularyKeys).subtracting(connectionKeys)
            .union(["customShortcutBindings", "rememberedOnDeviceLiveTranscriptionModel",
                    "rememberedRemoteLiveTranscriptionModel", "hasCompletedOnboarding",
                    "hasAnsweredAnalyticsConsent"])
    }
    static func category(for key: String) -> MigrationCategory? {
        if settingKeys.contains(key) {
            return .settings
        }
        if vocabularyKeys.contains(key) {
            return .vocabulary
        }
        if connectionKeys.contains(key) {
            return .connections
        }
        if credentialDefaults.contains(key) {
            return .credentials
        }
        return nil
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
        let values = try JSONDecoder().decode([AnyCodable].self, from: data)
        return try values.map { value in
            let object = value.value as? [String: Any] ?? [:]
            let id = try (object["id"] as? String ?? MigrationCoding
                .digest(MigrationCoding.encoder.encode(value)))
            var date: Date?
            if let text = object["timestamp"] as? String {
                date = ISO8601DateFormatter().date(from: text)
            }
            if let number = object["timestamp"] as? Double {
                date = Date(timeIntervalSinceReferenceDate: number) }
            return MigrationRecord(id: id, kind: collection.kind, value: value, date: date)
        }
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
            guard category == .credentials, record.value.value is String,
                  !record.id.hasPrefix("migration.recovery")
            else {
                throw MigrationError.invalid("Invalid credential")
            }
        case "history", "audio": try validateHistory(record, category: category)
        default: try validateCollection(record, category: category)
        }
    }
    private static func validateHistory(_ record: MigrationRecord, category: MigrationCategory) throws {
        guard category == (record.kind == "history" ? .history : .recordings),
              UUID(uuidString: record.id) != nil else {
            throw MigrationError.invalid("Invalid history identifier")
        }
        let item = try MigrationCoding.decode(HistoryItem.self, record.value)
        guard item.id.uuidString.lowercased() == record.id.lowercased(), item.recordingDuration >= 0,
              record.date.map({ abs(item.createdAt.timeIntervalSince($0)) < 1 }) == true
        else {
            throw MigrationError.invalid("Invalid history item")
        }
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
        case "profile": _ = try MigrationCoding.decode(DictationProfile.self, record.value)
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
