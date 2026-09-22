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
        /// Provider language the recording was transcribed with (`nil` means
        /// detection), so a retry repeats the original request exactly.
        public var languageIdentifier: String?
        /// The dictation profile applied to this recording, for display only;
        /// retries and imports never resolve a profile again.
        public var profileName: String?

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
        try write(record, to: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    public func records() throws -> [Record] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        // Surface corrupt records rather than silently hiding user history.
        return try files.map { try loadRecord(at: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(id: UUID) throws -> Record {
        try loadRecord(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    /// Resolves only a regular, non-symlinked audio file inside this store.
    /// Imported or hand-edited metadata never grants access outside History.
    /// Hard links and a swap between this check and a later write are outside
    /// what a path check can detect; a native handle-based boundary would be
    /// needed for those.
    public func audioURL(for record: Record) throws -> URL {
        let name = record.audioFilename
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(name)
        // The app never links audio into History; refusing links does not
        // depend on the host resolving them.
        guard try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        // Compare path components rather than URL directory-hint flags; corelibs
        // Foundation preserves those flags differently from Apple Foundation.
        guard url.deletingLastPathComponent().pathComponents == root.pathComponents,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    /// Metadata lives at `<UUID>.json`. Every read ties the decoded identity to
    /// that basename, so a corrupt or foreign file can never be saved over, or
    /// reported as, another record. Only regular, non-symlinked files are read.
    private func loadRecord(at url: URL) throws -> Record {
        guard let expected = Self.recordID(ofMetadataFile: url) else { throw CocoaError(.fileReadCorruptFile) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.id == expected else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    /// The canonical basename is the record's UUID string. Hex case is
    /// tolerated because UUID equality, not spelling, identifies the record.
    static func recordID(ofMetadataFile url: URL) -> UUID? {
        guard url.pathExtension == "json" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
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
    /// Nothing is ever deleted: unreadable files stay in place untouched.
    public func recoverInterruptedRecordings() throws -> RecoveryReport {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var recovered: [Record] = []
        var unreadable: [String] = []
        for file in files {
            do {
                var record = try loadRecord(at: file)
                if record.result == nil, record.failure == nil {
                    record.failure = recoverAudio(for: record)
                    // Rewrite the validated file itself, so an unusual basename
                    // spelling never gains a second copy under another name.
                    try write(record, to: file)
                }
                recovered.append(record)
            } catch { unreadable.append(file.lastPathComponent) }
        }
        return RecoveryReport(records: recovered.sorted { $0.createdAt > $1.createdAt }, unreadableFiles: unreadable)
    }

    /// Repairs only a WAV that audioURL(for:) resolves to a regular file inside
    /// History. Missing or unusable audio is reported, never written or removed.
    private func recoverAudio(for record: Record) -> String {
        let audio: URL
        do { audio = try audioURL(for: record) } catch {
            return "Recording was interrupted and its audio file is missing or unusable. Retry is unavailable."
        }
        guard audio.pathExtension.lowercased() == "wav" else {
            return "Transcription was interrupted. Imported audio retained for retry."
        }
        do {
            try PCMRecordingFile.recoverInterruptedFile(at: audio)
            return "Recording was interrupted. Audio recovered for retry."
        } catch {
            return "Recording was interrupted. Audio retained; recovery needs attention."
        }
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
