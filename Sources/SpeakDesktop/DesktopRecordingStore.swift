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
        public var processedText: String?
        public var postProcessingModelIdentifier: String?
        public var postProcessingFailure: String?

        public var displayText: String? { processedText ?? result?.text }

        /// The provider transcript exactly as transcribed, before post-processing.
        public var originalText: String? { result?.text }

        /// True when both transcripts are retained, so a host can offer an
        /// explicit original/processed choice instead of only `displayText`.
        public var hasTranscriptVariants: Bool { processedText != nil && result != nil }

        /// `.processed` keeps the historical `displayText` fallback to the
        /// original; `.original` never substitutes processed text.
        public func text(for variant: DesktopTranscriptVariant) -> String? {
            switch variant {
            case .processed: return displayText
            case .original: return originalText
            }
        }

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

    public func record(id: UUID) throws -> Record {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.id == id else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    /// Resolves only a regular audio file inside this store, including after
    /// symlink resolution. Imported metadata never grants access outside History.
    public func audioURL(for record: Record) throws -> URL {
        let name = record.audioFilename
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        // Compare path components rather than URL directory-hint flags; corelibs
        // Foundation preserves those flags differently from Apple Foundation.
        guard url.deletingLastPathComponent().pathComponents == root.pathComponents,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    public func exportTranscript(id: UUID, to destination: URL) throws {
        try exportTranscript(id: id, variant: .processed, to: destination)
    }

    /// Exports exactly the requested retained transcript. The stored record,
    /// its other transcript and its audio are never changed by an export.
    public func exportTranscript(id: UUID, variant: DesktopTranscriptVariant, to destination: URL) throws {
        let record = try record(id: id)
        guard let text = record.text(for: variant) else { throw CocoaError(.fileReadUnknown) }
        // A save dialog can accept a manually typed path. Never replace the
        // retained audio/metadata with its exported transcript.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !target.pathComponents.starts(with: root.pathComponents, by: {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
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

/// Which retained transcript a desktop host displays, copies or exports.
/// Retry and audio actions always use the original recording regardless.
public enum DesktopTranscriptVariant: String, CaseIterable, Codable, Sendable {
    /// Post-processed text when it exists, otherwise the original transcript.
    /// This is the default and matches the historical `displayText` behaviour.
    case processed
    /// The provider transcript before any post-processing.
    case original
}
