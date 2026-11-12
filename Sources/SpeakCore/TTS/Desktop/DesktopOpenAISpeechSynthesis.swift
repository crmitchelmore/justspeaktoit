import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopOpenAISpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        options: VoiceSynthesisOptions, credential: @Sendable () async throws -> String
    ) async throws -> Data {
        guard case .openai(let model, _) = voice else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
        let segments = try OpenAITTSAPI.synthesisSegments(source.text)
        let selection = OpenAITTSRequest(model: model, voiceID: voice.id, speed: options.speed)
        for segment in segments { try OpenAITTSAPI.validate(text: segment, request: selection) }
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw OpenAITTSAPIError.missingCredential }
        return try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: 24_000) { segment in
            try await synthesizeSegment(segment, key: key, selection: selection, voice: voice)
        }
    }

    func synthesizeRealtime(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, voiceID: String,
        options: VoiceSynthesisOptions, credential: @Sendable () async throws -> String
    ) async throws -> Data {
        guard OpenAIRealtimeSpeech.speedRange.contains(options.speed) else {
            throw OpenAIRealtimeSpeechError.unsupportedSpeed(options.speed)
        }
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw OpenAITTSAPIError.missingCredential }
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: source.text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: source.text.count)
        do {
            let result = try await OpenAIRealtimeSpeechSynthesizer(session: session)
                .synthesize(text: source.text, voice: voiceID, speed: options.speed, apiKey: key)
            guard result.pcm.count <= DeepgramSpeechExport.maximumPCMBytes else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            guard let wav = PCMWaveWriter.wavData(pcm: result.pcm, sampleRate: OpenAIRealtimeSpeech.sampleRate) else {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            if let ticket {
                capture?.finish(ticket, outcome: .completed,
                                audioDuration: Double(result.pcm.count) / Double(OpenAIRealtimeSpeech.sampleRate * 2))
            }
            return wav
        } catch {
            if let ticket { capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: OpenAITTSRequest, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try OpenAITTSAPI.synthesisRequest(text: text, apiKey: key, request: selection)
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: 24_000, requireComplete: true,
            begin: {
                $0.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                         usesSSML: false, pricingCharacters: text.count)
            },
            receive: { try await receive(request) }
        )
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        try await DesktopSpeechHTTP.receive(request, session: session) { http in
            guard http.statusCode == 200 else { throw OpenAITTSAPIError.service(http.statusCode) }
        }
    }
}
