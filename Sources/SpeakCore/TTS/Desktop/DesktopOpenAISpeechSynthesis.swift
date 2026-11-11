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
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesizeSegment(segment, key: key, selection: selection, voice: voice)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
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
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: text.count)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(received, sampleRate: 24_000, requireComplete: true)
            } catch {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            if let ticket { capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration) }
            return audio
        } catch {
            if let ticket { capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120)
            ) { http in
                guard http.statusCode == 200 else { throw OpenAITTSAPIError.service(http.statusCode) }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? OpenAITTSAPIError { throw service }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw DesktopSpeechSynthesisError.audioTooLarge
            case .timedOut: throw DesktopSpeechSynthesisError.timedOut
            case .invalidResponse: throw DesktopSpeechSynthesisError.invalidAudio
            case nil:
                throw (error as? URLError)?.code == .timedOut
                    ? DesktopSpeechSynthesisError.timedOut : DesktopSpeechSynthesisError.transportFailure
            }
        }
    }
}
