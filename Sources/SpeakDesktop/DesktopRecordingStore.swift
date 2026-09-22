import Foundation
import SpeakCore

/// Durable desktop records use the same transcription result on every platform.
/// Audio is written before a network request and retained after any failure.
public actor DesktopRecordingStore {
    public struct Record: Codable, Identifiable, Sendable {
        public let id: UUID
        public let createdAt: Date
        public let audioFilename: String
        public let modelIdentifier: String
        public var result: TranscriptionResult?
        public var failure: String?

        public init(id: UUID, audioFilename: String, modelIdentifier: String) {
            self.id = id
            self.createdAt = Date()
            self.audioFilename = audioFilename
            self.modelIdentifier = modelIdentifier
        }
    }

    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }

    public func records() throws -> [Record] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        // Surface corrupt records rather than silently hiding user history.
        return try files.map { try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Called once at launch, before capture starts. Recoverable recordings are
    /// retained for retry; corrupt metadata is reported without hiding good rows.
    public func recoverInterruptedRecordings() throws -> RecoveryReport {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var recovered: [Record] = []
        var unreadable: [String] = []
        for file in files {
            do {
                var record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                if record.result == nil, record.failure == nil {
                    // Only generated basenames may resolve inside the history directory.
                    guard URL(fileURLWithPath: record.audioFilename).lastPathComponent == record.audioFilename else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let audio = directory.appendingPathComponent(record.audioFilename)
                    if audio.pathExtension.lowercased() == "wav" {
                        do {
                            try PCMRecordingFile.recoverInterruptedFile(at: audio)
                            record.failure = "Recording was interrupted. Audio recovered for retry."
                        } catch {
                            record.failure = "Recording was interrupted. Audio retained; recovery needs attention."
                        }
                    } else {
                        record.failure = "Transcription was interrupted. Imported audio retained for retry."
                    }
                    try save(record)
                }
                recovered.append(record)
            } catch { unreadable.append(file.lastPathComponent) }
        }
        return RecoveryReport(records: recovered.sorted { $0.createdAt > $1.createdAt }, unreadableFiles: unreadable)
    }

    public struct RecoveryReport: Sendable {
        public let records: [Record]
        public let unreadableFiles: [String]
    }
}
