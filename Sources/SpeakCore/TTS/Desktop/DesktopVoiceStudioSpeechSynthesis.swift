import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded lossless desktop synthesis for local voice studios (Voicebox, VoiceStudio, GPT-SoVITS).
struct DesktopVoiceStudioSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        voice: VoiceStudioVoice,
        configuration: VoiceStudioConfiguration?,
        language: String?,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        guard let configuration, configuration.enabled else {
            throw VoiceStudioError.disabled
        }
        guard configuration.kind == voice.studioKind else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: VoiceStudioAPI.maxInputCharacters)
        guard !segments.isEmpty else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }

        let apiKey = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        _ = try VoiceStudioEndpointPolicy.validate(
            baseURLString: configuration.resolvedBaseURLString,
            apiKey: apiKey
        )
        if let gptError = configuration.gptSoVITSValidationError() {
            throw gptError
        }

        return try await DesktopSpeechHTTP.joinedWAV(
            segments,
            sampleRate: VoiceStudioWAV.canonicalSampleRate
        ) { segment in
            try await synthesizeSegment(
                segment,
                voice: voice,
                configuration: configuration,
                language: language,
                apiKey: apiKey
            )
        }
    }

    private func synthesizeSegment(
        _ text: String,
        voice: VoiceStudioVoice,
        configuration: VoiceStudioConfiguration,
        language: String?,
        apiKey: String
    ) async throws -> DeepgramSpeechAudio {
        let capture = VoiceSynthesisUsage.capture
        let desktopVoice = DesktopSpeechVoice.studio(voice)
        let ticket = capture.map {
            $0.begin(voice: desktopVoice, inputCharacters: text.unicodeScalars.count, usesSSML: false)
        }
        do {
            let normalized = try await VoiceStudioAPI.synthesize(
                text: text,
                voice: voice,
                configuration: configuration,
                apiKey: apiKey,
                language: language,
                session: session
            )
            try Task.checkCancellation()
            let audio = DeepgramSpeechAudio(
                wav: normalized.wavData,
                sampleRate: normalized.sampleRate,
                frameCount: normalized.frameCount
            )
            if let ticket {
                capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration)
            }
            return audio
        } catch {
            if let ticket {
                capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed)
            }
            throw error
        }
    }
}
