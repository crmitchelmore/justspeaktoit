import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func transcribePreparedAudio(
        _ audio: URL, model: String, key: String, duration: TimeInterval,
        language: String? = nil, keywords: [String] = [], azureEndpoint: String? = nil
    ) async throws -> TranscriptionResult {
        try await transcribePreparedAudio(
            audio, model: model, key: key, duration: duration, language: language,
            keywords: keywords, azureEndpoint: azureEndpoint, historySaved: true
        )
    }

    package func transcribePreparedAudio(
        _ audio: URL, model: String, key: String, duration: TimeInterval,
        language: String? = nil, keywords: [String] = [], azureEndpoint: String? = nil, historySaved: Bool
    ) async throws -> TranscriptionResult {
        var request = DesktopHostTranscriptionRequest(
            audio: audio, model: model, key: key, duration: duration,
            language: language, keywords: keywords, azureEndpoint: azureEndpoint
        )
        request.historySaved = historySaved
        return try await transcribePreparedAudio(request)
    }

    // swiftlint:disable:next line_length
    package func transcribePreparedAudio(_ request: DesktopHostTranscriptionRequest) async throws -> TranscriptionResult {
        let (audio, model, key, duration, language, keywords) = (
            request.audio, request.model, request.key, request.duration, request.language, request.keywords
        )
        let historySaved = request.historySaved
        let modulateFeatures = request.modulateFeatures
        try Task.checkCancellation()
        // Captured once, before any await: a long conversion must not pick up
        // an Azure endpoint the user changed mid-flight.
        let endpoint = request.azureEndpoint ?? azureResourceEndpoint()
        let canonicalDuration = try? NativePCM16WAVReader.canonicalDuration(at: audio)
        let local = DesktopHostModels.isLocal(model)
        if local, canonicalDuration != nil {
            return try await Platform.transcribeLocally(audio, model: model, language: language, controller: self)
        }
        guard local || DesktopTranscription.requiresCanonicalPCM16WAV(model: model), canonicalDuration == nil else {
            return try await DesktopTranscription.transcribe(
                audioURL: audio, model: model, apiKey: key, duration: canonicalDuration ?? duration,
                language: language, azureEndpoint: endpoint, modulateFeatures: modulateFeatures,
                staging: uploadStaging, keywords: keywords
            )
        }
        if historySaved { update("Preparing audio… Your original file is saved in History.", state: 2) }
        let conversionDirectory = directory.appendingPathComponent("ConvertedAudio")
        try Platform.preparePrivateDirectory(conversionDirectory)
        let output = conversionDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        // The converter owns partial-file cleanup. Only a successful conversion
        // transfers its output here; a collision must never remove an older file.
        let convertedDuration = try await Platform.convertAudio(input: audio, output: output)
        var converted = DesktopHostTranscriptionRequest(
            audio: output, model: model, key: key, duration: convertedDuration,
            language: language, keywords: keywords, azureEndpoint: endpoint
        )
        converted.modulateFeatures = modulateFeatures
        converted.historySaved = historySaved
        return try await transcribeConvertedAudio(
            converted, endpoint: endpoint, local: local, historySaved: historySaved
        )
    }

    private func transcribeConvertedAudio(
        _ request: DesktopHostTranscriptionRequest, endpoint: String, local: Bool, historySaved: Bool
    ) async throws -> TranscriptionResult {
        let result: TranscriptionResult
        do {
            try Task.checkCancellation()
            if local {
                result = try await Platform.transcribeLocally(
                    request.audio, model: request.model, language: request.language, controller: self
                )
            } else {
                if historySaved { update("Transcribing… Your original file is saved in History.", state: 2) }
                result = try await DesktopTranscription.transcribe(
                    audioURL: request.audio, model: request.model, apiKey: request.key, duration: request.duration,
                    language: request.language, azureEndpoint: endpoint, modulateFeatures: request.modulateFeatures,
                    staging: uploadStaging, keywords: request.keywords
                )
            }
        } catch {
            try removeConvertedAudio(request.audio, historySaved: historySaved, failure: error)
            throw error
        }
        try removeConvertedAudio(request.audio, historySaved: historySaved)
        return result
    }

    func removeConvertedAudio(
        _ audio: URL, historySaved: Bool, failure: Error? = nil,
        remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        if historySaved { try? remove(audio); return }
        guard FileManager.default.fileExists(atPath: audio.path) else { return }
        do {
            try remove(audio)
        } catch {
            throw DesktopHostError(
                message: "Read-only transcription could not remove transient audio at \(audio.path). "
                    + "The original input is unchanged; no History record was created. "
                    + (failure.map { "Transcription failed: \($0.localizedDescription). " } ?? "")
                    + "Cleanup failed: \(error.localizedDescription)"
            )
        }
    }
}
