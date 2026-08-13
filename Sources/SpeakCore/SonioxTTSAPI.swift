import Foundation

/// Errors surfaced by the shared Soniox speech-generation transport.
///
/// Each platform client maps these onto its own error type so existing
/// user-facing behaviour is preserved.
public enum SonioxTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    /// HTTP 401/403 — the key is missing, wrong or revoked.
    case unauthorized(statusCode: Int, message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
    /// The request exceeded Soniox's per-request text limit.
    case textTooLong(limit: Int, characterCount: Int)
}

/// Output containers the app requests from Soniox.
public enum SonioxTTSAudioFormat: String, Codable, Hashable, Sendable {
    case mp3
    case aac
    case wav
}

/// One speech-generation request, with Soniox's documented limits applied on
/// construction so callers cannot build an out-of-range request.
public struct SonioxTTSRequest: Sendable {
    public let model: SonioxTTSModel
    /// Language code of the input text, for example `en`.
    public let language: String
    public let voice: SonioxTTSVoice
    public let audioFormat: SonioxTTSAudioFormat
    public let sampleRate: Int?
    /// Speaking rate, clamped to the range Soniox accepts.
    public let speed: Double

    public init(
        model: SonioxTTSModel = SonioxTTSCatalog.defaultModel,
        language: String,
        voice: SonioxTTSVoice,
        audioFormat: SonioxTTSAudioFormat,
        sampleRate: Int? = nil,
        speed: Double = 1.0
    ) {
        self.model = model
        self.language = language
        self.voice = voice
        self.audioFormat = audioFormat
        self.sampleRate = sampleRate.flatMap { SonioxTTSAPI.supportedSampleRates.contains($0) ? $0 : nil }
        self.speed = min(max(speed, SonioxTTSAPI.speedRange.lowerBound), SonioxTTSAPI.speedRange.upperBound)
    }

    func jsonBody(text: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "language": language,
            "voice": voice.apiVoiceName,
            "audio_format": audioFormat.rawValue,
            "text": text,
            "speed": speed
        ]
        if let sampleRate {
            body["sample_rate"] = sampleRate
        }
        return body
    }
}

/// Shared Soniox text-to-speech transport.
///
/// Owns request construction, authentication headers and response
/// classification only — audio playback, file handling and cost accounting stay
/// with each platform caller. The API key travels solely in the `Authorization`
/// header and is never logged or embedded in errors.
public struct SonioxTTSAPI: Sendable {
    /// Speech-generation endpoint.
    public static let speakEndpoint = URL(string: "https://tts-rt.soniox.com/tts")!
    /// Cheap authenticated endpoint used to validate API keys.
    public static let modelsEndpoint = URL(string: "https://api.soniox.com/v1/tts-models")!
    /// Soniox rejects requests above this length.
    public static let maxTextLength = 5000
    /// Speaking rates Soniox accepts.
    public static let speedRange: ClosedRange<Double> = 0.7...1.3
    /// Output sample rates Soniox accepts.
    public static let supportedSampleRates: Set<Int> = [8000, 16_000, 24_000, 44_100, 48_000]
    /// Soniox bills per token and summarises real-time speech generation as
    /// roughly $0.70 per hour of generated audio.
    public static let costPerHourOfSpeech = Decimal(string: "0.70")!
    /// Character-based estimate for the same rate, using ~45,000 spoken
    /// characters per hour. Used before synthesis, when no duration exists yet.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.0156")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// POSTs `text` to the speech endpoint and returns the generated audio bytes.
    ///
    /// - Parameters:
    ///   - text: Text to speak, at most ``maxTextLength`` characters.
    ///   - apiKey: Soniox API key, sent as `Bearer` authorization.
    ///   - request: Model, language, voice and output settings.
    public func synthesize(
        text: String,
        apiKey: String,
        request: SonioxTTSRequest
    ) async throws -> Data {
        guard text.count <= Self.maxTextLength else {
            throw SonioxTTSAPIError.textTooLong(limit: Self.maxTextLength, characterCount: text.count)
        }

        var urlRequest = URLRequest(url: Self.speakEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request.jsonBody(text: text))

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonioxTTSAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SonioxTTSAPIError.unauthorized(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SonioxTTSAPIError.httpError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        return data
    }

    /// Validates a Soniox API key against the TTS models endpoint.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "Empty API key")
        }

        var request = URLRequest(url: Self.modelsEndpoint)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(message: "Invalid response")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                return .success(message: "Soniox API key is valid")
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failure(message: "Soniox rejected the key (HTTP \(httpResponse.statusCode))")
            } else {
                return .failure(message: "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// Soniox reports failures as JSON with an `error_message`; fall back to the
    /// raw body when the payload is not the documented shape.
    static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = payload["error_message"] as? String,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
