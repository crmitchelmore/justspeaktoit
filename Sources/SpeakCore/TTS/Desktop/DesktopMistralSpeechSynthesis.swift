import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopMistralSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice, inventory: VoiceAccountInventory?,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
        guard !segments.isEmpty else { throw DesktopSpeechSynthesisError.invalidAudio }
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw VoiceAccountDiscoveryError.missingCredential(.mistral) }
        guard inventory?.mistral != nil, inventory?.contains(voice) == true,
              inventory?.matchesCredential(key) == true else {
            throw VoiceAccountDiscoveryError.credentialChanged(.mistral)
        }
        let selection = MistralTTSRequest(voiceID: voice.id, responseFormat: .wav)
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesizeSegment(segment, key: key, selection: selection,
                                                    voice: voice, inventory: inventory)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: voice.sampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        try Task.checkCancellation()
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: MistralTTSRequest, voice: DesktopSpeechVoice,
        inventory: VoiceAccountInventory?
    ) async throws -> DeepgramSpeechAudio {
        let request = try MistralTTSAPI.synthesisRequest(input: text, apiKey: key, request: selection)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: false,
                                   pricingCharacters: text.count, accountInventory: inventory)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(
                    MistralTTSAPI.decodedAudio(from: received), sampleRate: voice.sampleRate)
            } catch {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            try Task.checkCancellation()
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
            ) { response in
                guard (200..<300).contains(response.statusCode) else {
                    throw DesktopMistralSpeechError.service(response.statusCode)
                }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? DesktopMistralSpeechError { throw service }
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

public enum DesktopMistralSpeechError: LocalizedError, Equatable {
    case service(Int)

    public var errorDescription: String? {
        switch self {
        case .service(401): "Mistral rejected the saved Voice key. Check the key and workspace."
        case .service(403): "Mistral denied speech: check model access, account tier or text moderation."
        case .service(429): "Mistral speech is rate limited. Try again later."
        case .service(let status): "Mistral speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
