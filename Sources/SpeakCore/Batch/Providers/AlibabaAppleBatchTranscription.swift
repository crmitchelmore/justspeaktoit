#if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
import AVFoundation
import Foundation

public enum AlibabaAppleBatchTranscription {
    public static func transcribeFile(
        at url: URL, credentials: String, model: String, language: String?, session: URLSession = .shared
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = try AlibabaSpeechConfiguration(credentials: credentials)
        try config.validateModel(model)
        guard AlibabaSpeechModels.batchIDs.contains(model) else { throw AlibabaSpeechError.unsupportedModel }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= AlibabaBatchTranscriptionClient.maximumAudioBytes else {
            throw AlibabaSpeechError.audioTooLarge
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0 else { throw AlibabaSpeechError.invalidDuration }
        let duration = Double(file.length) / rate
        guard duration <= (model == AlibabaSpeechModels.funFlash ? 300 : 10_800) else {
            throw AlibabaSpeechError.durationExceeded
        }
        // A general audio-understanding model can describe silence. Do not send
        // digitally silent input to a generative model or allow placeholder text.
        if try !hasAudio(file) {
            return TranscriptionResult(
                text: "", segments: [], confidence: nil, duration: duration, modelIdentifier: model,
                cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        return try await AlibabaBatchTranscriptionClient(session: session).transcribeFile(
            at: url, credentials: credentials, model: model, duration: duration, language: language
        )
    }

    private static func hasAudio(_ file: AVAudioFile) throws -> Bool {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw AlibabaSpeechError.unsupportedFormat
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw AlibabaSpeechError.unsupportedFormat
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) where abs(channels[channel][frame]) > 0.000_01 {
                    return true
                }
            }
        }
        return false
    }
}
#endif
