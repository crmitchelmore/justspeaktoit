#if os(iOS)
import AVFoundation
import Foundation
import os.log

/// Deepgram Aura TTS client for iOS.
/// Converts text to speech using Deepgram's Aura API.
@MainActor
public final class DeepgramTTSClient: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isSpeaking = false
    @Published private(set) public var error: Error?

    // MARK: - Private

    private var audioPlayer: AVAudioPlayer?
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "DeepgramTTS")

    // MARK: - Configuration

    public var model: String = "aura-2"
    public var voice: String = "asteria"
    public var speed: Double = 1.0

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Convert text to speech and play it.
    public func speak(text: String, apiKey: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.isEmpty else {
            throw DeepgramTTSError.missingAPIKey
        }

        logger.info("TTS request: \(text.prefix(50))...")

        let audioData = try await synthesize(text: text, apiKey: apiKey)
        try await playAudio(audioData)
    }

    /// Convert text to speech and return audio data without playing.
    public func synthesize(text: String, apiKey: String) async throws -> Data {
        guard !apiKey.isEmpty else {
            throw DeepgramTTSError.missingAPIKey
        }

        // Deepgram model format: aura-2-{voice}-en or aura-{voice}-en
        let modelParam = "\(model)-\(voice)-en"
        let url = URL(string: "https://api.deepgram.com/v1/speak?model=\(modelParam)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramTTSError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepgramTTSError.apiError(statusCode: httpResponse.statusCode, message: body)
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
