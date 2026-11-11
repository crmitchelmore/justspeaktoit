import AVFoundation
import Foundation
import os.log

/// Batch transcription for `OpenRouterAPIClient`: OpenRouter audio models
/// through `OpenRouterAudioClient`, other models through the portable
/// inline-audio client, enriched with an AVFoundation duration.
struct OpenRouterFileTranscription: Sendable {
    private static let logger = SpeakLogger.logger(category: "OpenRouter")

    let session: URLSession
    let maximumInlineAudioBytes: Int64
    let branding: OpenRouterBranding

    /// Uses the stored key when there is one; without it only on-device and
    /// Apple models fall back to a placeholder transcript.
    func transcribe(at url: URL, model: String, language: String?, apiKey: String?) async throws
        -> TranscriptionResult {
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = apiKey {
            if cleanedModel.hasPrefix(OpenRouterTranscriptionSelection.prefix) {
                guard let rawModel = OpenRouterTranscriptionSelection.modelID(from: cleanedModel) else {
                    throw OpenRouterAudioError.invalidInput
                }
                let audioClient = OpenRouterAudioClient(
                    apiKeyProvider: { key }, session: session,
                    maximumInputBytes: Int(clamping: maximumInlineAudioBytes)
                )
                return try await audioClient.transcribe(
                    audioFileURL: url,
                    model: rawModel,
                    language: language
                )
            }
            return try await performRemoteTranscription(
                apiKey: key, url: url, model: cleanedModel, language: language)
        }

        if OpenRouterLocalFallback.allows(model: cleanedModel) {
            let duration = await Self.bestEffortDuration(of: url)
            return OpenRouterLocalFallback.transcription(of: url, model: cleanedModel, duration: duration)
        }

        throw OpenRouterClientError.apiKeyMissing
    }

    /// The shared inline-audio contract, enriched with this actor's best-effort
    /// duration so a transcript is never lost to unreadable container metadata.
    private func performRemoteTranscription(
        apiKey: String,
        url: URL,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let client = OpenRouterInlineAudioTranscriptionClient(
            apiKey: apiKey,
            session: session,
            maximumInlineAudioBytes: maximumInlineAudioBytes,
            branding: branding,
            durationResolver: { audioURL in await Self.bestEffortDuration(of: audioURL) }
        )
        return try await client.transcribeFile(at: url, model: model, language: language)
    }

    /// Reads the recorded length of `audioURL`, and reports `0` when the local
    /// file gives no usable value.
    ///
    /// Duration is enrichment that is added after the provider replies. A
    /// container that AVFoundation cannot parse, or that holds no duration
    /// metadata, must not discard a transcript the provider already made — the
    /// audio is frequently a temporary file that is deleted immediately after,
    /// so a thrown error loses the speech and the transcript together.
    ///
    /// `TranscriptionResult.duration` is a non-optional `TimeInterval`, and all
    /// consumers already read `0` as "unknown": speech insights skip sessions
    /// below the minimum length, and the history and recording lists show
    /// `0:00`. Cost is separate metadata and stays `nil` here. The failure is
    /// logged so a run with missing durations stays diagnosable.
    static func bestEffortDuration(of audioURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: audioURL)
        do {
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0 else {
                Self.logger.warning(
                    "Duration metadata for \(audioURL.lastPathComponent, privacy: .public) is not usable; reporting 0"
                )
                return 0
            }
            return seconds
        } catch {
            Self.logger.warning(
                """
                Failed to load duration metadata for \
                \(audioURL.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public). Keeping the transcript with duration 0
                """
            )
            return 0
        }
    }
}
