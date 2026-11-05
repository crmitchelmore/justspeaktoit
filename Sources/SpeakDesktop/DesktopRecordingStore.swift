import Foundation
import SpeakCore

/// Durable desktop records use the same transcription result on every platform.
/// Audio is written before a network request and retained after any failure.
public actor DesktopRecordingStore {
    public struct Record: Codable, Identifiable, Sendable {
        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey, CaseIterable {
            case id, createdAt, audioFilename, modelIdentifier, result, failure, processedText
            case correctedText, lexiconSummary, lexiconDirectives, lexiconContextTags
            case postProcessingModelIdentifier, postProcessingFailure, languageIdentifier, profileName, profileNotes
            case originPlatform, migrationMetadata, recordedDuration, importedCost, importedModelIdentifiers
            case localAudio
            case livePolishResult
        }

        public let id: UUID
        public let createdAt: Date
        public let audioFilename: String
        /// Local descriptive provenance, usable only with a separately verified ownership registration.
        public internal(set) var localAudio: DesktopRecordingAudioReference?
        public let modelIdentifier: String
        public var result: TranscriptionResult?
        public var failure: String?
        public var processedText: String?
        public var correctedText: String?
        public var lexiconSummary: PersonalLexiconHistorySummary?
        public var lexiconDirectives: [String]?
        public var lexiconContextTags: [String]?
        public var postProcessingModelIdentifier: String?
        public var postProcessingFailure: String?
        public var livePolishResult: LivePolishSession.Result?
        /// Provider language the recording was transcribed with (`nil` means
        /// detection), so a retry repeats the original request exactly.
        public var languageIdentifier: String?
        /// The dictation profile applied to this recording, for display only;
        /// retries and imports never resolve a profile again.
        public var profileName: String?
        public var profileNotes: [String]?
        /// The platform that recorded a transcript synced in from iCloud, such
        /// as `macos`. `nil` for a recording made on this device. A synced copy
        /// has no audio here: its audio never leaves the device that recorded it.
        public var originPlatform: String?
        /// Original imported wire metadata, including fields this host cannot edit.
        public var migrationMetadata: AnyCodable?
        public var recordedDuration: TimeInterval?
        public var importedCost: ApplicationHistoryCost?
        public var importedModelIdentifiers: [String]?

        public var recordingDuration: TimeInterval? { result?.duration ?? recordedDuration }
        public var recordingCost: ApplicationHistoryCost? {
            result?.cost.map { .init(total: $0.totalCost, currency: $0.currency, breakdown: $0) } ?? importedCost
        }

        /// True for a transcript that arrived through History sync.
        public var isSyncedCopy: Bool { originPlatform != nil }

        public var displayText: String? { processedText ?? correctedText ?? result?.text }

        /// The provider transcript exactly as transcribed, before post-processing.
        public var originalText: String? { result?.text }

        /// True when both transcripts are retained, so a host can offer an
        /// explicit original/processed choice instead of only `displayText`.
        public var hasTranscriptVariants: Bool { (processedText != nil || correctedText != nil) && result != nil }

        /// `.processed` keeps the historical `displayText` fallback to the
        /// original; `.original` never substitutes processed text.
        public func text(for variant: DesktopTranscriptVariant) -> String? {
            switch variant {
            case .processed: return displayText
            case .original: return originalText
            }
        }

        public init(id: UUID, audioFilename: String, modelIdentifier: String, createdAt: Date = Date()) {
            self.id = id
            self.createdAt = createdAt
            self.audioFilename = audioFilename
            self.modelIdentifier = modelIdentifier
        }

        public init(capture: DesktopRecordingLocations.Capture, modelIdentifier: String, createdAt: Date = Date()) {
            self.init(
                id: capture.recordingID, audioFilename: capture.recordingID.uuidString + ".wav",
                modelIdentifier: modelIdentifier, createdAt: createdAt
            )
            localAudio = capture.reference
        }

        /// A transcript synced from another device. It keeps that device's
        /// identity and creation time, and has no audio file.
        public init(syncedID id: UUID, createdAt: Date, modelIdentifier: String, originPlatform: String) {
            self.id = id
            self.createdAt = createdAt
            self.audioFilename = ""
            self.modelIdentifier = modelIdentifier
            self.originPlatform = originPlatform
        }
    }

    public let directory: URL
    var deletionLedger: DesktopHistoryDeletionLedger
    var audioLocations: DesktopRecordingLocations?

    public init(directory: URL, audioLocations: DesktopRecordingLocations? = nil) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try audioLocations?.validateHistory(directory)
        self.audioLocations = audioLocations
        deletionLedger = try DesktopHistoryDeletionLedger.load(from: directory)
    }

    public func save(_ record: Record) throws {
        try requireRetained(record.id)
        try write(record, to: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    public func records() throws -> [Record] {
        let files = try metadataFiles()
        // Surface corrupt records rather than silently hiding user history.
        return try files.filter { !isDeletedMetadata($0) }.map { try loadRecord(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func record(id: UUID) throws -> Record {
        try requireRetained(id)
        return try loadRecord(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    /// Every record that reads cleanly, newest first. Sync uses this so one
    /// corrupt file cannot stop other History from syncing; the corrupt file
    /// itself is still reported by `records()` and recovery, never touched.
    public func readableRecords() throws -> [Record] {
        let files = try metadataFiles()
        return files.filter { !isDeletedMetadata($0) }.compactMap { try? loadRecord(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The record with this identity if it exists and reads cleanly.
    public func existingRecord(id: UUID) -> Record? {
        try? record(id: id)
    }

    /// Removes a transcript that was synced in from another device after it
    /// was deleted there. A recording made on this device, or anything with
    /// an audio file, is never removed this way: `false` means it was kept.
    @discardableResult
    public func removeSyncedCopy(id: UUID) throws -> Bool {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let record = try loadRecord(at: url)
        guard record.isSyncedCopy, record.audioFilename.isEmpty else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    /// Legacy audio stays in History; local references require separate verified ownership.
    /// Imported or hand-edited metadata alone never grants access outside History.
    /// A descriptive URL is not a held read or mutation grant. Use readAudio for
    /// strict bounded reads; external repair/deletion needs a separate owned capability.
    public func audioURL(for record: Record) throws -> URL {
        try requireRetained(record.id)
        return try ownedAudioURL(for: record)
    }

    func ownedAudioURL(for record: Record) throws -> URL {
        if record.localAudio != nil {
            guard let audioLocations else { throw DesktopRecordingLocationError.unregistered }
            return try audioLocations.resolve(record)
        }
        let name = record.audioFilename
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.utf8.contains(0) else {
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
    func loadRecord(at url: URL) throws -> Record {
        guard let expected = Self.recordID(ofMetadataFile: url) else { throw CocoaError(.fileReadCorruptFile) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.id == expected else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    /// The metadata files in History. Listing by path fails on every platform
    /// when History cannot be opened as a folder. The URL listing in
    /// swift-corelibs-foundation reports a path that is not a folder, or (on
    /// Linux) one it cannot open, as empty, which would show, sync and recover
    /// an unreadable History as one with no recordings.
    func metadataFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .map { directory.appendingPathComponent($0, isDirectory: false) }
            .filter { $0.pathExtension == "json" }
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
        try exportTranscriptSnapshot(text, to: destination)
    }

    /// Exports text captured from the visible transcript before an async action
    /// or save dialog. Later retries cannot change the content the user chose.
    public func exportTranscriptSnapshot(_ text: String, to destination: URL) throws {
        _ = try exportTranscriptSnapshot(text, to: destination, admitting: { true })
    }

    /// A retired request may refuse a queued write after protected-path validation.
    /// Admission is synchronous: an atomic write already admitted may finish.
    package func exportTranscriptSnapshot(
        _ text: String, to destination: URL, admitting: @Sendable () -> Bool
    ) throws -> Bool {
        // A save dialog can accept a manually typed path. Never replace the
        // retained audio/metadata with its exported transcript.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !target.pathComponents.starts(with: root.pathComponents, by: {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }), audioLocations?.protectsAudioDestination(target) != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard admitting() else { return false }
        try Data(text.utf8).write(to: destination, options: .atomic)
        return true
    }

    /// Called once at launch, before capture starts. Recoverable recordings are
    /// retained for retry; corrupt metadata is reported without hiding good rows.
    /// Nothing is ever deleted: unreadable files stay in place untouched.
    public func recoverInterruptedRecordings() throws -> RecoveryReport {
        let files = try metadataFiles()
        var recovered: [Record] = []
        var unreadable: [String] = []
        for file in files where !isDeletedMetadata(file) {
            do {
                var record = try loadRecord(at: file)
                // A synced copy is complete as received; it has no audio to recover.
                if record.result == nil, record.failure == nil, !record.isSyncedCopy {
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

    /// Repairs only legacy WAVs inside History. External audio requires a held repair capability.
    /// Missing or unusable audio is reported, never written or removed.
    private func recoverAudio(for record: Record) -> String {
        let audio: URL
        do { audio = try audioURL(for: record) } catch {
            return "Recording was interrupted and its audio file is missing or unusable. Retry is unavailable."
        }
        guard record.localAudio == nil else {
            return "Recording was interrupted. Audio retained; owned external-audio repair is not implemented."
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
