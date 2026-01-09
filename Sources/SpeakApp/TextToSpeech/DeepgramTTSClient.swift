import SpeakCore
import AVFoundation
import Foundation

/// Deepgram Aura TTS client - ultra-low latency text-to-speech (~250ms first byte)
actor DeepgramTTSClient: TextToSpeechClient {
    let provider: TTSProvider = .deepgram
    private let baseURL = URL(string: "https://api.deepgram.com/v1/speak")!
    private let session: URLSession
    private let secureStorage: SecureAppStorage

    init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
        self.secureStorage = secureStorage
        self.session = session
    }

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
            !apiKey.isEmpty
        else {
            throw TTSError.apiKeyMissing(provider)
        }

        let voiceID = voice.replacingOccurrences(of: "deepgram/", with: "")

        // Build URL with query parameters
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: voiceID),
            URLQueryItem(name: "encoding", value: encodingFormat(for: settings.format)),
        ]

        // `container` is not applicable for MP3 (and can trigger HTTP 400).
        if settings.format == .wav {
            components.queryItems?.append(URLQueryItem(name: "container", value: containerFormat(for: settings.format)))
        }

        // `sample_rate` is not applicable for MP3 (and can trigger HTTP 400).
        if settings.format == .wav {
            // Add sample rate for better quality
            if settings.quality == .highest {
                components.queryItems?.append(URLQueryItem(name: "sample_rate", value: "48000"))
            } else if settings.quality == .high {
                components.queryItems?.append(URLQueryItem(name: "sample_rate", value: "24000"))
            }
        }

        guard let url = components.url else {
            throw TTSError.synthesisFailure("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.synthesisFailure("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TTSError.apiKeyMissing(provider)
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSError.synthesisFailure("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Save audio data to temporary file
        let outputURL = try await saveAudioData(data, format: settings.format)

        // Calculate duration
        let duration = try await getAudioDuration(url: outputURL)

        // Deepgram Aura pricing: $0.0135 per 1000 characters
        let cost = Decimal(text.count) * Decimal(string: "0.0135")! / 1000

        return TTSResult(
            audioURL: outputURL,
            provider: provider,
            voice: voice,
            duration: duration,
            characterCount: text.count,
            cost: cost
        )
    }

    func listVoices() async throws -> [TTSVoice] {
        return VoiceCatalog.deepgramVoices
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        // Use the projects endpoint to validate
        guard let url = URL(string: "https://api.deepgram.com/v1/projects") else {
            return .failure(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(message: "Invalid response")
            }

            if httpResponse.statusCode == 200 {
                return .success(message: "API key is valid")
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failure(message: "Invalid API key")
            } else {
                return .failure(message: "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func encodingFormat(for format: AudioFormat) -> String {
        switch format {
        case .mp3: return "mp3"
        case .m4a: return "aac"
        case .wav: return "linear16"
        }
    }

    private func containerFormat(for format: AudioFormat) -> String {
        switch format {
        case .mp3: return "none"  // Raw MP3 stream (Deepgram containers: wav|ogg|none)
        case .m4a: return "none"  // Raw AAC
        case .wav: return "wav"
        }
    }

    private func saveAudioData(_ data: Data, format: AudioFormat) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "tts_\(UUID().uuidString).\(format.fileExtension)"
        let fileURL = tempDir.appendingPathComponent(filename)

        try data.write(to: fileURL)
        return fileURL
    }

    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
}
