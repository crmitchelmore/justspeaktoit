import Foundation
import SpeakCore

extension DesktopRecordingStore {
    /// Commits an independent flat audio copy, never a transcript or journal.
    /// The actor serializes publication with History's audio-only housekeeping.
    public func archiveVoiceAudio(_ audio: VoiceGeneratedAudio, identifier: UUID = UUID()) throws -> URL {
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(identifier.uuidString + ".wav")
        let staging = directory.appendingPathComponent(".voice-archive-\(UUID().uuidString).partial")
        do {
            try audio.wav.write(to: staging, options: .withoutOverwriting)
            try Task.checkCancellation()
            // Linking this independent staging inode commits atomically and
            // exclusively: an existing destination is never replaced.
            try FileManager.default.linkItem(at: staging, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do { try FileManager.default.removeItem(at: staging) } catch let cleanup {
                    throw VoiceArchiveCleanupFailure(original: error, cleanup: cleanup)
                }
            }
            throw error
        }
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            throw VoiceArchiveCommittedCleanupFailure(filename: destination.lastPathComponent, cleanup: error)
        }
        return destination
    }
}

private struct VoiceArchiveCleanupFailure: LocalizedError {
    let original: Error
    let cleanup: Error

    var errorDescription: String? {
        "Voice audio save failed: \(original.localizedDescription) Temporary audio cleanup also failed: "
            + cleanup.localizedDescription
    }
}

package struct VoiceArchiveCommittedCleanupFailure: LocalizedError {
    let filename: String
    let cleanup: Error

    package var errorDescription: String? {
        "Audio was saved as \(filename), but its temporary archive link could not be removed: "
            + cleanup.localizedDescription + " The saved copy was kept."
    }
}
