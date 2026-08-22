#if os(iOS)
import AVFoundation
import CryptoKit
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

                return RecordingInfo(
                    id: stableRecordingID(for: url),
                    url: url,
                    startedAt: created,
                    duration: 0,
                    fileSize: size
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Stable identity for a recording on disk, derived from its file name, so
    /// the same file yields the same `id` on every listing. `RecordingInfo` is
    /// `Identifiable`/`Hashable`: SwiftUI diffing and any selection or
    /// pending-delete state keyed on `id` break if it changes between
    /// refreshes. (The file name's 8-character suffix is not a UUID, so it
    /// cannot simply be parsed back.)
    public static func stableRecordingID(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(url.lastPathComponent.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
