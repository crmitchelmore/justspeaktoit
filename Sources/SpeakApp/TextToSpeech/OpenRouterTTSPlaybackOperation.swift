import Foundation
import SpeakCore

struct TTSSynthesisOutput {
    let result: TTSResult
    let playbackCompleted: Bool
}

/// Owns only one opted-in OpenRouter utterance, until its result is transferred
/// to the manager's existing publication/file owner.
@MainActor
enum OpenRouterTTSPlaybackOperation {
    static func synthesize(
        text: String, voice: String, settings: TTSSettings,
        client: OpenRouterTTSClient, player: TTSProgressivePlayer
    ) async throws -> TTSSynthesisOutput {
        try Task.checkCancellation()
        let owner: TTSProgressivePlaybackState.SessionID
        do {
            owner = try player.prepareOwned(sampleRate: OpenRouterProgressiveSpeechResult.sampleRate)
        } catch TTSError.audioPlaybackFailure {
            // No request has begun. A local engine setup limitation can use the
            // original file path once, without retrying a billable request.
            try Task.checkCancellation()
            let result = try await client.synthesize(text: text, voice: voice, settings: settings)
            return try transfer(result, playbackCompleted: false)
        }
        do {
            let response = try await client.synthesizeProgressively(text: text, voice: voice) { [weak player] chunk in
                guard let player else { throw CancellationError() }
                try await player.enqueue(chunk, session: owner)
            }
            do {
                try Task.checkCancellation()
                guard response.pcmProduced != response.completedFileRequired else {
                    throw TTSError.audioPlaybackFailure
                }
                // A fallback response has no scheduled PCM, but still checks
                // exact ownership before handing its same completed file back.
                try await player.waitUntilDrained(session: owner)
                try Task.checkCancellation()
                player.stop(session: owner)
                return TTSSynthesisOutput(result: response.result, playbackCompleted: response.pcmProduced)
            } catch {
                try? FileManager.default.removeItem(at: response.result.audioURL)
                throw error
            }
        } catch {
            player.stop(session: owner)
            throw error
        }
    }

    private static func transfer(_ result: TTSResult, playbackCompleted: Bool) throws -> TTSSynthesisOutput {
        do {
            try Task.checkCancellation()
            return TTSSynthesisOutput(result: result, playbackCompleted: playbackCompleted)
        } catch {
            try? FileManager.default.removeItem(at: result.audioURL)
            throw error
        }
    }
}
