#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

// MARK: - Saved-recording library

extension AudioRecordingPersistence {
    // MARK: - Listing & Management

    /// List all saved recordings, newest first.
    ///
    /// Durations are not read here: opening each file just to ask for its
    /// length stalls the main thread on large libraries. Entries are returned
    /// with `duration == 0`; load real values asynchronously per file with
    /// `loadDuration(for:)`.
    public static func listRecordings() -> [RecordingInfo] {
        let dir = recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let validExt: Set<String> = ["m4a", "wav", "aac", "caf"]

        return files
            .filter { validExt.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> RecordingInfo? in
                let res = try? url.resourceValues(
                    forKeys: [.creationDateKey, .fileSizeKey]
                )
                let created = res?.creationDate ?? Date()
                let size = Int64(res?.fileSize ?? 0)

                let stem = url.deletingPathExtension().lastPathComponent
                let cleanStem = stem
                    .replacingOccurrences(of: "Recording-", with: "")
                let rid = UUID(uuidString: String(cleanStem.suffix(8))) ?? UUID()

                return RecordingInfo(
                    id: rid,
                    url: url,
                    startedAt: created,
                    duration: 0,
                    fileSize: size
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Load a recording's duration without blocking the calling thread.
    /// `AVURLAsset` reads just the metadata it needs, off the main thread.
    public static func loadDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Delete a specific recording file.
    public static func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Supporting Types

public struct RecordingInfo: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let startedAt: Date
    public let duration: TimeInterval
    public let fileSize: Int64
    /// Persistence truth for a recording captured this session; `nil` for
    /// entries listed from disk, whose session diagnostics are gone.
    public var diagnostics: RecordingPersistenceDiagnostics?

    init(
        id: UUID,
        url: URL,
        startedAt: Date,
        duration: TimeInterval,
        fileSize: Int64,
        diagnostics: RecordingPersistenceDiagnostics? = nil
    ) {
        self.id = id
        self.url = url
        self.startedAt = startedAt
        self.duration = duration
        self.fileSize = fileSize
        self.diagnostics = diagnostics
    }
}

public enum AudioPersistenceError: LocalizedError {
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A persistent recording session is already active."
        }
    }
}
#endif
