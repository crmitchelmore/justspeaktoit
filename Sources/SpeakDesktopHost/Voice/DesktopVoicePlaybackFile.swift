import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopVoicePlaybackFile {
    static func writeExport(_ wav: Data, to destination: URL) async throws {
        let writer = Task.detached {
            try Task.checkCancellation()
            try DesktopVoiceExportPublication.write(wav, to: destination)
        }
        try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
    }

    static func play(
        _ audio: VoiceGeneratedAudio, directory: URL,
        prepare: @escaping @Sendable (URL) throws -> Void,
        through playback: @escaping @Sendable (URL) async throws -> TimeInterval
    ) async throws {
        let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = Task.detached {
            try Task.checkCancellation()
            try prepare(directory)
            try audio.wav.write(to: file, options: .withoutOverwriting)
        }
        do {
            try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
            try Task.checkCancellation()
            _ = try await playback(file)
            try FileManager.default.removeItem(at: file)
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) } catch let cleanup {
                    throw DesktopHostError(message:
                        "Generated audio failed: \(error.localizedDescription) Temporary playback cleanup failed: "
                            + cleanup.localizedDescription)
                }
            }
            throw error
        }
    }
}
