#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation

extension OpenRouterAudioClient {
    /// Streams explicitly requested MP3 into the private final file and the
    /// shared native decoder. The consumer must await actual owned scheduling
    /// or throw cancellation on replacement; silently discarding PCM would
    /// falsely acknowledge playback. Chunks contain at most 100 ms of PCM.
    public func synthesizeProgressively(
        text: String,
        model: String,
        voice: String?,
        speed: Double? = nil,
        onPCM: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> OpenRouterProgressiveSpeechResult {
        let request = try await speechRequest(text: text, model: model, voice: voice, speed: speed)
        let destination = temporaryDirectory.appendingPathComponent("openrouter-\(UUID().uuidString).mp3")
        let operation = OpenRouterProgressiveSpeech(onPCM: onPCM)
        do {
            _ = try await OpenRouterAudioDownload.perform(
                request: request, session: session, destination: destination,
                limit: maximumSpeechBytes, speech: true, onBytes: { try await operation.append($0) }
            )
            let disposition = try await operation.finish()
            try Task.checkCancellation()
            return OpenRouterProgressiveSpeechResult(
                speech: OpenRouterSpeechResult(audioURL: destination), pcmProduced: disposition.pcmProduced,
                completedFileRequired: disposition.completedFileRequired
            )
        } catch {
            await operation.cancel()
            try? FileManager.default.removeItem(at: destination)
            throw Self.audioError(from: error)
        }
    }
}
#endif
