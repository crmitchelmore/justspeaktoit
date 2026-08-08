import SpeakCore
import AVFoundation
import Foundation

/// Deepgram Aura TTS client - ultra-low latency text-to-speech (~250ms first byte)
///
/// HTTP transport lives in `SpeakCore.DeepgramTTSAPI`, shared with the iOS
/// client; this wrapper adds keychain lookup, file handling and cost tracking.
actor DeepgramTTSClient: TextToSpeechClient {
    let provider: TTSProvider = .deepgram
    private let api: DeepgramTTSAPI
    private let secureStorage: SecureAppStorage

    init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
        self.secureStorage = secureStorage
        self.api = DeepgramTTSAPI(session: session)
    }

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
            !apiKey.isEmpty
        else {
            throw TTSError.apiKeyMissing(provider)
        }

        let voiceID = voice.replacingOccurrences(of: "deepgram/", with: "")

        var queryItems = [
            URLQueryItem(name: "model", value: voiceID),
            URLQueryItem(name: "encoding", value: encodingFormat(for: settings.format)),
        ]

        // `container` and `sample_rate` are not applicable for MP3 (and can
        // trigger HTTP 400).
        if settings.format == .wav {
            queryItems.append(URLQueryItem(name: "container", value: containerFormat(for: settings.format)))

            // Add sample rate for better quality
            if settings.quality == .highest {
                queryItems.append(URLQueryItem(name: "sample_rate", value: "48000"))
            } else if settings.quality == .high {
                queryItems.append(URLQueryItem(name: "sample_rate", value: "24000"))
            }
        }

        let data: Data
        do {
            data = try await api.synthesize(text: text, apiKey: apiKey, queryItems: queryItems)
        } catch let error as DeepgramTTSAPIError {
            switch error {
            case .unauthorized:
                throw TTSError.apiKeyMissing(provider)
            case .httpError(let statusCode, let message):
                throw TTSError.synthesisFailure("HTTP \(statusCode): \(message)")
            case .invalidURL:
                throw TTSError.synthesisFailure("Invalid URL")
            case .invalidResponse:
                throw TTSError.synthesisFailure("Invalid response")
            }
        }

        // Save audio data to temporary file
        let outputURL = try await saveAudioData(data, format: settings.format)

        // Calculate duration
        let duration = try await getAudioDuration(url: outputURL)

        let cost = Decimal(text.count) * DeepgramTTSAPI.costPerThousandCharacters / 1000

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
        await api.validateAPIKey(key)
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
