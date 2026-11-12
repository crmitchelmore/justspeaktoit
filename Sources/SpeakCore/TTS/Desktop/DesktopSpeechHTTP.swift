import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP steps every desktop voice that returns WAV segments shares: one
/// bounded request per segment, its usage record, and joining the segments
/// into one WAV that is published only when every segment succeeded. What a
/// request carries and what a rejected response means stay with the provider.
enum DesktopSpeechHTTP {
    /// Synthesizes `segments` in order and joins their PCM into one WAV at
    /// `sampleRate`, refusing audio past the export limit.
    static func joinedWAV<Segment>(
        _ segments: [Segment], sampleRate: Int,
        synthesize: (Segment) async throws -> DeepgramSpeechAudio
    ) async throws -> Data {
        var pcm = Data()
        for segment in segments {
            try Task.checkCancellation()
            let audio = try await synthesize(segment)
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

    /// Receives one segment as canonical WAV and records it with the task's
    /// usage capture: completed with its duration, cancelled or failed.
    /// `begin` opens the record, immediately before transport.
    static func measuredSegment(
        sampleRate: Int, requireComplete: Bool = false,
        begin: (VoiceSynthesisUsage.Capture) -> UUID,
        receive: () async throws -> Data
    ) async throws -> DeepgramSpeechAudio {
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture.map(begin)
        do {
            let received = try await receive()
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(
                    received, sampleRate: sampleRate, requireComplete: requireComplete)
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

    /// One bounded request whose status `accept` checks before the body is
    /// read. An error `accept` throws reaches the caller unchanged unless the
    /// task was cancelled; transport failures become `DesktopSpeechSynthesisError`.
    static func receive(
        _ request: URLRequest, session: URLSession,
        accept: @escaping @Sendable (HTTPURLResponse) throws -> Void
    ) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120),
                accept: { response in
                    do { try accept(response) } catch { throw Rejected(error: error) }
                }
            ).body
        } catch {
            if isCancellation(error) { throw CancellationError() }
            if let rejected = error as? Rejected { throw rejected.error }
            throw transportError(error)
        }
    }

    /// One bounded request whose rejection `serviceError` reads from the
    /// response body. Cancellation wins over whatever the provider answered.
    static func receive(
        _ request: URLRequest, session: URLSession,
        serviceError: (_ body: Data, _ statusCode: Int) -> Error
    ) async throws -> Data {
        let response: OpenRouterBoundedResponseTransport.Response
        do {
            response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120))
        } catch {
            throw isCancellation(error) ? CancellationError() : transportError(error)
        }
        guard (200..<300).contains(response.http.statusCode) else {
            if Task.isCancelled { throw CancellationError() }
            throw serviceError(response.body, response.http.statusCode)
        }
        return response.body
    }

    private struct Rejected: Error {
        let error: Error
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func transportError(_ error: Error) -> Error {
        switch error as? OpenRouterBoundedResponseTransport.Failure {
        case .responseTooLarge: DesktopSpeechSynthesisError.audioTooLarge
        case .timedOut: DesktopSpeechSynthesisError.timedOut
        case .invalidResponse: DesktopSpeechSynthesisError.invalidAudio
        case nil:
            (error as? URLError)?.code == .timedOut
                ? DesktopSpeechSynthesisError.timedOut : DesktopSpeechSynthesisError.transportFailure
        }
    }
}
