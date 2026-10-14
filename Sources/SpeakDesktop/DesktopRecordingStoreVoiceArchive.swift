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
            try DesktopFilePublication.commit(staging: staging, destination: destination)
        } catch let committed as DesktopFilePublicationCleanupFailure {
            throw VoiceArchiveCommittedCleanupFailure(
                filename: committed.destination.lastPathComponent, cleanup: committed.cleanup
            )
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do { try FileManager.default.removeItem(at: staging) } catch let cleanup {
                    throw VoiceArchiveCleanupFailure(original: error, cleanup: cleanup)
                }
            }
            throw error
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
