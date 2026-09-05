#if os(iOS)
import AVFoundation
import Foundation
import os.log
import SpeakCore

/// Deepgram Aura TTS client for iOS.
/// Converts text to speech using Deepgram's Aura API.
///
/// HTTP transport lives in `SpeakCore.DeepgramTTSAPI`, shared with the macOS
/// client; this wrapper adds audio-session management and playback.
@MainActor
public final class DeepgramTTSClient: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isSpeaking = false
    @Published private(set) public var error: Error?

    // MARK: - Private

    private var audioPlayer: AVAudioPlayer?
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
    }

    // MARK: - Public API

    /// Convert text to speech and play it.
    public func speak(text: String, apiKey: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            throw DeepgramTTSError.missingAPIKey
        }

        let audioData = try await synthesize(text: text, apiKey: apiKey)
        try await playAudio(audioData)
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
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    // MARK: - Private

    private func playAudio(_ data: Data) async throws {
        stop()

        do {
            // Use playAndRecord so we don't tear down the mic session
            // when conversation mode will immediately resume recording.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.enableRate = true
            audioPlayer?.rate = Float(speed)
            audioPlayer?.prepareToPlay()

            isSpeaking = true
            audioPlayer?.play()

            // Wait for playback to complete
            while audioPlayer?.isPlaying == true {
                try await Task.sleep(for: .milliseconds(30))
            }

            isSpeaking = false
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            isSpeaking = false
            self.error = error
            throw error
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
