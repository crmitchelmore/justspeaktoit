import Foundation
import SpeakCore

public enum DesktopMigrationHistory {
    public static func record(
        _ imported: DataMigrationRecord, category: DataMigrationCategory, audioFilename: String = ""
    ) throws -> DesktopRecordingStore.Record {
        let item = try DataMigrationHistorySchema.validate(imported, category: category)
        guard audioFilename.isEmpty || (audioFilename != "." && audioFilename != ".."
            && !audioFilename.contains("/") && !audioFilename.contains("\\")
            && !audioFilename.contains(":") && !audioFilename.contains("\0")) else {
            throw DataMigrationError.invalid("Invalid imported recording filename")
        }
        let native: DesktopRecordingStore.Record?
        if let desktop = item.desktopHistory {
            // Preserve the original raw field in migrationMetadata, but never decode imported local authority.
            var sanitized = desktop
            if case .object(var fields) = desktop.storage {
                fields.removeValue(forKey: "localAudio")
                sanitized = AnyCodable(.object(fields))
            }
            native = try JSONDecoder().decode(DesktopRecordingStore.Record.self, from: JSONEncoder().encode(sanitized))
        } else {
            native = nil
        }
        let model = native?.modelIdentifier
            ?? item.modelUsages.first(where: { $0.phase != .postProcessing })?.modelIdentifier
            ?? item.modelsUsed.first ?? "migration/imported"
        let createdAt = native.flatMap {
            abs($0.createdAt.timeIntervalSince(item.createdAt)) < 1 ? $0.createdAt : nil
        } ?? item.createdAt
        var record = DesktopRecordingStore.Record(
            id: item.id, audioFilename: audioFilename, modelIdentifier: model, createdAt: createdAt
        )
        record.recordedDuration = item.recordingDuration
        record.importedCost = item.cost
        record.importedModelIdentifiers = item.modelsUsed + item.modelUsages.map(\.modelIdentifier)
        record.migrationMetadata = imported.value
        record.processedText = item.postProcessedTranscription
        record.postProcessingModelIdentifier = native?.postProcessingModelIdentifier
            ?? item.modelUsages.first(where: { $0.phase == .postProcessing })?.modelIdentifier
        record.languageIdentifier = native?.languageIdentifier
        record.profileName = native?.profileName
        record.profileNotes = native?.profileNotes
        record.failure = native?.failure ?? item.errors.first(where: { $0.phase != .postProcessing })?.message
        record.postProcessingFailure = native?.postProcessingFailure
            ?? item.errors.first(where: { $0.phase == .postProcessing })?.message
        if let text = item.rawTranscription {
            let result = native?.result
            record.result = TranscriptionResult(
                text: text, segments: result?.text == text ? result?.segments ?? [] : [],
                confidence: result?.text == text ? result?.confidence : nil,
                duration: item.recordingDuration, modelIdentifier: model,
                cost: item.cost?.breakdown, rawPayload: nil, debugInfo: nil
            )
        }
        return record
    }

    public static func value(
        _ record: DesktopRecordingStore.Record, audioOnly: Bool = false
    ) throws -> AnyCodable {
        var object: [String: AnyCodable.JSONValue]
        if let original = record.migrationMetadata {
            _ = try DataMigrationCoding.decode(ApplicationHistoryItem.self, original)
            guard case .object(let fields) = original.storage else {
                throw DataMigrationError.invalid("Invalid retained migration metadata")
            }
            object = fields
        } else {
            object = try initialValue(record)
        }
        object["id"] = .string(record.id.uuidString)
        object["createdAt"] = .string(ISO8601DateFormatter().string(from: record.createdAt))
        object["recordingDuration"] = .double(record.recordingDuration ?? 0)
        object["rawTranscription"] = record.originalText.map(AnyCodable.JSONValue.string)
        object["postProcessedTranscription"] = record.processedText.map(AnyCodable.JSONValue.string)
        var native = record
        native.migrationMetadata = nil
        let metadata = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(native))
        if case .object(var desktop) = metadata.storage {
            desktop.removeValue(forKey: "localAudio")
            desktop["audioFilename"] = .string("")
            if case .object(var original) = object["desktopHistory"] {
                // Imported machine-local authority stays only in retained metadata, never in portable export.
                original.removeValue(forKey: "localAudio")
                for key in ["recordedDuration", "importedCost", "importedModelIdentifiers"] where original[key] == nil {
                    desktop.removeValue(forKey: key)
                }
                desktop["originPlatform"] = original["originPlatform"]
                for key in DesktopRecordingStore.Record.CodingKeys.allCases
                    where key != .localAudio && desktop[key.rawValue] == nil {
                    original.removeValue(forKey: key.rawValue)
                }
                desktop = original.merging(desktop) { _, current in current }
            }
            if record.migrationMetadata == nil || object["desktopHistory"] != nil
                || record.languageIdentifier != nil || record.profileName != nil || record.profileNotes != nil {
                object["desktopHistory"] = .object(desktop)
            }
        }
        return try DataMigrationHistoryValue.value(AnyCodable(.object(object)), audioOnly: audioOnly)
    }

    private static func initialValue(_ record: DesktopRecordingStore.Record) throws -> [String: AnyCodable.JSONValue] {
        let phase: ApplicationModelUsagePhase = ModelCatalog.liveTranscription.contains {
            $0.id == record.modelIdentifier
        } ? .transcriptionLive : .transcriptionBatch
        let usages = (record.modelIdentifier.isEmpty ? [] : [
            ApplicationModelUsage(modelIdentifier: record.modelIdentifier, phase: phase)
        ])
            + (record.postProcessingModelIdentifier.map {
                [ApplicationModelUsage(modelIdentifier: $0, phase: .postProcessing)]
            } ?? [])
        var postProcessingErrorID = record.id.uuid
        postProcessingErrorID.15 ^= 1
        let errors = record.failure.map {
            [ApplicationHistoryError(id: record.id, phase: .transcription, message: $0, occurredAt: record.createdAt)]
        } ?? []
        let postProcessingErrors = record.postProcessingFailure.map {
            [ApplicationHistoryError(id: UUID(uuid: postProcessingErrorID), phase: .postProcessing,
                                     message: $0, occurredAt: record.createdAt)]
        } ?? []
        let item = ApplicationHistoryItem(
            id: record.id, createdAt: record.createdAt, updatedAt: record.createdAt,
            modelsUsed: usages.map(\.modelIdentifier), modelUsages: usages,
            rawTranscription: record.originalText, postProcessedTranscription: record.processedText,
            recordingDuration: record.recordingDuration ?? 0,
            cost: record.recordingCost,
            audioFileURL: nil, networkExchanges: [], events: [], phaseTimestamps: .init(),
            trigger: .init(gesture: .uiButton, hotKeyDescription: "Desktop history (trigger not retained)",
                           outputMethod: .none), personalCorrections: nil, errors: errors + postProcessingErrors,
            source: record.modelIdentifier.isEmpty ? .importedFile : nil
        )
        guard case .object(let fields) = try DataMigrationCoding.value(item).storage else {
            throw DataMigrationError.invalid("Invalid desktop history metadata")
        }
        return fields
    }
}
