import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func transcribePreparedAudio(
        _ audio: URL, model: String, key: String, duration: TimeInterval, language: String? = nil
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let canonicalDuration = try? NativePCM16WAVReader.canonicalDuration(at: audio)
        guard DesktopTranscription.requiresCanonicalPCM16WAV(model: model), canonicalDuration == nil else {
            return try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: key,
                duration: canonicalDuration ?? duration, language: language, staging: uploadStaging
            )
        }
        update("Preparing audio… Your original file is saved in History.", state: 2)
        let conversionDirectory = directory.appendingPathComponent("ConvertedAudio")
        try Platform.preparePrivateDirectory(conversionDirectory)
        let output = conversionDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        // The converter owns partial-file cleanup. Only a successful conversion
        // transfers its output here; a collision must never remove an older file.
        let convertedDuration = try await Platform.convertAudio(input: audio, output: output)
        defer { try? FileManager.default.removeItem(at: output) }
        try Task.checkCancellation()
        update("Transcribing… Your original file is saved in History.", state: 2)
        return try await DesktopTranscription.transcribe(
            audioURL: output, model: model, apiKey: key,
            duration: convertedDuration, language: language, staging: uploadStaging
        )
    }
}
