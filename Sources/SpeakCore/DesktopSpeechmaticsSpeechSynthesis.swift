import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopSpeechmaticsSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let segments = SpeechTextSegmenter.segments(source.text)
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopSpeechmaticsSpeechError.missingCredential }
        let selection = SpeechmaticsTTSRequest(voiceID: voice.id)
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
        guard !pcm.isEmpty,
              let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: selection.outputFormat.sampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, selection: SpeechmaticsTTSRequest, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try SpeechmaticsTTSAPI.synthesisRequest(text: text, apiKey: key, request: selection)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: text.count)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(
                    received, sampleRate: selection.outputFormat.sampleRate, requireComplete: true)
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
            let response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120))
            guard (200..<300).contains(response.http.statusCode) else {
                throw DesktopSpeechmaticsSpeechError(SpeechmaticsTTSAPI.error(
                    from: response.body, statusCode: response.http.statusCode))
            }
            return response.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? DesktopSpeechmaticsSpeechError { throw service }
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

public enum DesktopSpeechmaticsSpeechError: LocalizedError, Equatable {
    case emptyText, missingCredential, invalidResponse, unauthorized, quotaExceeded, rateLimited, service(Int)

    init(_ error: SpeechmaticsTTSAPIError) {
        switch error {
        case .emptyText: self = .emptyText
        case .invalidResponse: self = .invalidResponse
        case .unauthorized: self = .unauthorized
        case .quotaExceeded: self = .quotaExceeded
        case .rateLimited: self = .rateLimited
        case .httpError(let status, _): self = .service(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .missingCredential: "Save the shared Speechmatics API key to use Speechmatics Voice output."
        case .invalidResponse: "Speechmatics returned an invalid speech response. No audio was published."
        case .unauthorized: "Speechmatics rejected the saved key. Check the key in Settings."
        case .quotaExceeded: "Speechmatics speech credit is exhausted. Check the account balance."
        case .rateLimited: "Speechmatics speech quota or rate limit reached. Try again later."
        case .service(let status): "Speechmatics speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
