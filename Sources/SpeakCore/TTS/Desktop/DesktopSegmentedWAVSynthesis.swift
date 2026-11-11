import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP flow shared by desktop voices that return one complete WAV per
/// text segment (Groq Orpheus, Speechmatics). Each segment is one bounded
/// request with its own usage record; the PCM payloads are joined into one
/// WAV, and nothing is published unless every segment succeeds. How text is
/// segmented, what each request carries and what a rejected response means
/// stay with the provider.
struct DesktopSegmentedWAVSynthesis: Sendable {
    let session: URLSession
    let sampleRate: Int
    /// Builds the request for one segment with the resolved key.
    let request: @Sendable (_ text: String, _ key: String) throws -> URLRequest
    /// The provider's error for a non-2xx response.
    let serviceError: @Sendable (_ body: Data, _ statusCode: Int) -> Error

    func synthesize(
        _ segments: [String], voice: DesktopSpeechVoice, missingCredential: Error,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw missingCredential }
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesizeSegment(segment, key: key, voice: voice)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private func synthesizeSegment(
        _ text: String, key: String, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try request(text, key)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: text.count)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(received, sampleRate: sampleRate, requireComplete: true)
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
        let response: OpenRouterBoundedResponseTransport.Response
        do {
            response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120))
        } catch {
            throw Self.transportError(error)
        }
        guard (200..<300).contains(response.http.statusCode) else {
            // Cancellation wins over whatever the provider answered.
            if Task.isCancelled { throw CancellationError() }
            throw serviceError(response.body, response.http.statusCode)
        }
        return response.body
    }

    private static func transportError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        switch error as? OpenRouterBoundedResponseTransport.Failure {
        case .responseTooLarge: return DesktopSpeechSynthesisError.audioTooLarge
        case .timedOut: return DesktopSpeechSynthesisError.timedOut
        case .invalidResponse: return DesktopSpeechSynthesisError.invalidAudio
        case nil:
            return (error as? URLError)?.code == .timedOut
                ? DesktopSpeechSynthesisError.timedOut : DesktopSpeechSynthesisError.transportFailure
        }
    }
}
