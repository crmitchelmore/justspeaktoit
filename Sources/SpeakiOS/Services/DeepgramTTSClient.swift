#if os(iOS)
import AVFoundation
import Foundation
import os.log
import SpeakCore

/// Deepgram Aura TTS client for iOS.
/// Converts text to speech using Deepgram's Aura API.
///
/// HTTP transport lives in `SpeakCore.DeepgramTTSAPI`, shared with the macOS
/// client; playback and the audio-session lease belong to
/// ``VoiceOutputAudioPlayback``, as for every iOS voice-output provider.
@MainActor
public final class DeepgramTTSClient: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isSpeaking = false
    @Published private(set) public var error: Error?

    // MARK: - Private

    private var playback: VoiceOutputAudioPlayback?
    private let makePlayback: () -> VoiceOutputAudioPlayback
    private let api: DeepgramTTSAPI
    private let logger = SpeakLogger.logger(category: "DeepgramTTS")

    // MARK: - Configuration

    public var model: String = DeepgramTTSCatalog.defaultModel.id
    public var voice: String =
        DeepgramTTSCatalog.defaultVoice(for: DeepgramTTSCatalog.defaultModel).id
    public var speed: Double = 1.0

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.api = DeepgramTTSAPI(session: session)
        self.makePlayback = { VoiceOutputAudioPlayback() }
    }

    /// Lets ownership tests play through fake audio boundaries.
    init(session: URLSession, makePlayback: @escaping () -> VoiceOutputAudioPlayback) {
        self.api = DeepgramTTSAPI(session: session)
        self.makePlayback = makePlayback
    }

    // MARK: - Public API

    /// Convert text to speech and play it.
    public func speak(text: String, apiKey: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            throw DeepgramTTSError.missingAPIKey
        }

        let audioData = try await synthesize(text: text, apiKey: apiKey)
        try await play(audioData)
    }

    /// Convert text to speech and return audio data without playing.
    public func synthesize(text: String, apiKey: String) async throws -> Data {
        guard !apiKey.isEmpty else {
            throw DeepgramTTSError.missingAPIKey
        }

        let modelParam = DeepgramSpeechCatalog.resolvedSelection(
            modelID: model,
            voiceID: voice
        ).voice.id

        let data: Data
        do {
            data = try await api.synthesize(
                text: text,
                apiKey: apiKey,
                queryItems: [URLQueryItem(name: "model", value: modelParam)]
            )
        } catch let error as DeepgramTTSAPIError {
            switch error {
            case .invalidURL, .invalidResponse:
                throw DeepgramTTSError.invalidResponse
            case .unauthorized(let statusCode, let message),
                .httpError(let statusCode, let message):
                throw DeepgramTTSError.apiError(statusCode: statusCode, message: message)
            }
        }

        logger.info("TTS synthesis complete: \(data.count) bytes")
        return data
    }

    /// Stop any currently playing audio.
    public func stop() {
        playback?.stop()
        playback = nil
        isSpeaking = false
    }

    // MARK: - Playback

    /// Plays synthesized audio to the end. `stop()` ends it quietly, as it
    /// always has; cancelling the calling task stops the audio too.
    func play(_ data: Data) async throws {
        stop()
        let operation = makePlayback()
        playback = operation
        defer {
            if playback === operation {
                playback = nil
                isSpeaking = false
            }
        }
        do {
            let rate = VoiceOutputAudioPlayback.playbackRate(for: speed, in: VoiceOutputProvider.deepgram.speedRange)
            try operation.start(.data(data), rate: rate)
            isSpeaking = true
            try await operation.waitForCompletion()
        } catch is CancellationError where playback !== operation {
            return
        } catch {
            operation.stop()
            if error is CancellationError { throw error }
            let surfaced: Error = (error as? VoiceOutputPlaybackError) == .playbackFailed
                ? DeepgramTTSError.playbackFailed : error
            self.error = surfaced
            throw surfaced
        }
    }
}

// MARK: - Error

public enum DeepgramTTSError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case playbackFailed

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Deepgram API key is required for text-to-speech"
        case .invalidResponse:
            return "Invalid response from Deepgram TTS API"
        case .apiError(let code, let message):
            return "Deepgram TTS error (\(code)): \(message)"
        case .playbackFailed:
            return "Failed to play synthesized audio"
        }
    }
}
#endif
