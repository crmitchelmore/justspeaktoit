import Foundation

public enum DataMigrationHistoryValue {
    public static func value(
        _ source: AnyCodable, audioOnly: Bool = false, audioURL: URL? = nil, id: String? = nil
    ) throws -> AnyCodable {
        _ = try DataMigrationCoding.decode(ApplicationHistoryItem.self, source)
        guard case .object(var object) = source.storage else {
            throw DataMigrationError.invalid("Invalid history item")
        }
        object.removeValue(forKey: "audioFileURL")
        object["networkExchanges"] = .array([])
        object.removeValue(forKey: "diagnosticContext")
        if let audioURL { object["audioFileURL"] = .string(audioURL.absoluteString) }
        if let id { object["id"] = .string(id) }
        object["desktopHistory"] = redactedDesktop(object["desktopHistory"], audioOnly: audioOnly, id: id)
        if audioOnly {
            for key in [
                "rawTranscription", "postProcessedTranscription", "postProcessingPrompt", "personalCorrections"
            ] {
                object.removeValue(forKey: key)
            }
            object["events"] = .array([])
            object["errors"] = .array([])
        }
        return try DataMigrationCoding.decoder.decode(
            AnyCodable.self, from: DataMigrationCoding.encoder.encode(AnyCodable(.object(object)))
        )
    }

    private static func redactedDesktop(
        _ source: AnyCodable.JSONValue?, audioOnly: Bool, id: String?
    ) -> AnyCodable.JSONValue? {
        if case .object(var desktop) = source {
            desktop.removeValue(forKey: "migrationMetadata")
            if desktop["audioFilename"] != nil { desktop["audioFilename"] = .string("") }
            if let id { desktop["id"] = .string(id) }
            if case .object(var result) = desktop["result"] {
                result.removeValue(forKey: "debugInfo")
                result.removeValue(forKey: "rawPayload")
                desktop["result"] = .object(result)
            }
            if audioOnly {
                for key in ["result", "processedText", "failure", "postProcessingFailure"] {
                    desktop.removeValue(forKey: key)
                }
            }
            return .object(desktop)
        }
        return source
    }
}
