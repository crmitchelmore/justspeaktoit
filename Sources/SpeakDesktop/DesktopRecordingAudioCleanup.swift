import Foundation
import SpeakCore

public struct DesktopRecordingAudioSnapshot: Sendable {
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    let directory: URL
    let entries: [Entry]

    struct Entry: Sendable {
        let filename: String
        let identity: Identity
    }

    struct Identity: Equatable, Sendable {
        let size: UInt64
        let modified: Date
        let created: Date?
        let device: UInt64?
        let file: UInt64?
    }
}

public struct DesktopRecordingAudioCleanupOutcome: Sendable {
    public struct Failure: Sendable {
        public let filename: String
        public let message: String
    }

    public internal(set) var removed = 0
    public internal(set) var missing = 0
    public internal(set) var cancelled = false
    public internal(set) var failures: [Failure] = []
}

public enum DesktopRecordingAudioCleanupError: Error, LocalizedError, Sendable {
    case unsafeFile
    case changedFile
    case changedDirectory

    public var errorDescription: String? {
        switch self {
        case .unsafeFile: return "Saved audio is linked, non-regular, or has unreadable ownership information."
        case .changedFile: return "Saved audio changed after confirmation. The replacement was kept."
        case .changedDirectory: return "The recording storage location changed. No audio was removed."
        }
    }
}

extension DesktopRecordingStore {
    /// Only flat, app-owned audio belongs to this operation. Synthesis, conversion
    /// and comparison staging folders are not recording archives.
    public func snapshotSavedAudio(excluding filenames: Set<String> = []) throws -> DesktopRecordingAudioSnapshot {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var known = Set(deletionLedger.intents.values.map(\.audioFilename))
        for file in try metadataFiles() {
            try Task.checkCancellation()
            known.insert(try loadRecord(at: file).audioFilename)
        }
        var entries: [DesktopRecordingAudioSnapshot.Entry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
            try Task.checkCancellation()
            guard !filenames.contains(name),
                  RecordingAudioFormats.archiveExtensions.contains(
                    URL(fileURLWithPath: name).pathExtension.lowercased()
                  ),
                  known.contains(name) || Self.isCanonicalRecordingAudio(name) else { continue }
            let record = Record(id: UUID(), audioFilename: name, modelIdentifier: "")
            let url = try ownedAudioURL(for: record)
            entries.append(.init(filename: name, identity: try Self.audioCleanupIdentity(at: url)))
        }
        return DesktopRecordingAudioSnapshot(directory: root, entries: entries)
    }

    /// No History metadata or tombstones are changed. Cancellation stops before
    /// the next file; a new explicit confirmation retries any remaining audio.
    public func removeSavedAudio(
        _ snapshot: DesktopRecordingAudioSnapshot
    ) throws -> DesktopRecordingAudioCleanupOutcome {
        guard directory.resolvingSymlinksInPath().standardizedFileURL == snapshot.directory else {
            throw DesktopRecordingAudioCleanupError.changedDirectory
        }
        var outcome = DesktopRecordingAudioCleanupOutcome()
        for entry in snapshot.entries {
            if Task.isCancelled { outcome.cancelled = true; break }
            do {
                let record = Record(id: UUID(), audioFilename: entry.filename, modelIdentifier: "")
                let url = try ownedAudioURL(for: record)
                guard try Self.audioCleanupIdentity(at: url) == entry.identity else {
                    throw DesktopRecordingAudioCleanupError.changedFile
                }
                try FileManager.default.removeItem(at: url)
                outcome.removed += 1
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                outcome.missing += 1
            } catch {
                outcome.failures.append(.init(filename: entry.filename, message: error.localizedDescription))
            }
        }
        return outcome
    }

    private static func isCanonicalRecordingAudio(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return RecordingAudioFormats.archiveExtensions.contains(url.pathExtension.lowercased())
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    static func audioCleanupIdentity(at url: URL) throws -> DesktopRecordingAudioSnapshot.Identity {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date,
              (values[.referenceCount] as? NSNumber)?.uint64Value ?? 1 == 1 else {
            throw DesktopRecordingAudioCleanupError.unsafeFile
        }
        return .init(
            size: size.uint64Value, modified: modified, created: values[.creationDate] as? Date,
            device: (values[.systemNumber] as? NSNumber)?.uint64Value,
            file: (values[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
