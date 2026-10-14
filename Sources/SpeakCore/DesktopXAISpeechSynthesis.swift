import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native hosts use the shared REST contract, never the separate xAI realtime protocol.
struct DesktopXAISpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions,
        inventory: XAIAccountVoiceInventory?,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: XAITTSAPI.maximumTextCharacters)
        guard !segments.isEmpty else { throw DesktopSpeechSynthesisError.invalidAudio }
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopXAISpeechError.missingCredential }
        if !DesktopSpeechVoice.voices.contains(voice) {
            guard inventory?.contains(voice) == true, inventory?.matchesCredential(key) == true else {
                throw XAIAccountVoiceDiscoveryError.credentialChanged
            }
        }
        let selection = XAITTSRequest(
            voiceID: voice.id, language: nil, codec: .wav, sampleRate: XAITTSAPI.defaultSampleRate,
            speed: options.speed)
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesizeSegment(
                segment, key: key, selection: selection, voice: voice, inventory: inventory)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: XAITTSAPI.defaultSampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: XAITTSRequest, voice: DesktopSpeechVoice,
        inventory: XAIAccountVoiceInventory?
    ) async throws -> DeepgramSpeechAudio {
        let request = try XAITTSAPI.synthesisRequest(text: text, apiKey: key, request: selection)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                                   usesSSML: false, xaiInventory: inventory)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do { audio = try DeepgramSpeechWAV.canonical(received, sampleRate: XAITTSAPI.defaultSampleRate) } catch {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            if let ticket { capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration) }
            return audio
        } catch {
            if let ticket {
                capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed)
            }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120)
            ) { response in
                guard (200..<300).contains(response.statusCode) else {
                    throw DesktopXAISpeechError.service(response.statusCode)
                }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? DesktopXAISpeechError { throw service }
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

public enum DesktopXAISpeechError: LocalizedError, Equatable {
    case missingCredential
    case service(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Save an xAI API key to use xAI Voice output."
        case .service(401), .service(403): "xAI rejected the saved key or speech access. Check the key and account."
        case .service(402): "The xAI account has no speech credit. Check the account's billing."
        case .service(404): "xAI does not expose the selected voice on this account. Choose an available voice."
        case .service(429): "xAI speech is rate limited. Try again later."
        case .service(let status): "xAI speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
