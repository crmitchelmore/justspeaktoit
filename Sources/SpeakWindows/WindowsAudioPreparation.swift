import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsAppController {
    func transcribePreparedAudio(
        _ audio: URL, model: String, key: String, duration: TimeInterval, language: String? = nil
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let canonicalDuration = try? NativePCM16WAVReader.canonicalDuration(at: audio)
        let local = WindowsModels.isLocal(model)
        if local, canonicalDuration != nil {
            return try await transcribeLocally(audio, model: model, language: language)
        }
        guard local || DesktopTranscription.requiresCanonicalPCM16WAV(model: model), canonicalDuration == nil else {
            return try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: key, duration: canonicalDuration ?? duration,
                language: language, azureEndpoint: azureResourceEndpoint(), staging: uploadStaging
            )
        }
        update("Preparing audio… Your original file is saved in History.", state: 2)
        let conversionDirectory = directory.appendingPathComponent("ConvertedAudio")
        try conversionDirectory.path.withCString { path in
            try WindowsNative.checked { jsti_private_directory_prepare(path, $0, $1) }
        }
        let output = conversionDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        // The converter owns partial-file cleanup. Only a successful conversion
        // transfers its output here; a collision must never remove an older file.
        let converted = try await WindowsAudioConversion.convert(input: audio, output: output)
        defer { try? FileManager.default.removeItem(at: output) }
        try Task.checkCancellation()
        if local { return try await transcribeLocally(output, model: model, language: language) }
        update("Transcribing… Your original file is saved in History.", state: 2)
        return try await DesktopTranscription.transcribe(
            audioURL: output, model: model, apiKey: key, duration: converted.duration,
            language: language, azureEndpoint: azureResourceEndpoint(), staging: uploadStaging
        )
    }
}
