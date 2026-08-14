import Foundation

/// Errors surfaced by the shared Soniox speech-generation transport.
///
/// Each platform client maps these onto its own error type so existing
/// user-facing behaviour is preserved.
public enum SonioxTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    /// The request exceeded Soniox's per-request text limit.
    case textTooLong(limit: Int, characterCount: Int)
    /// Stable provider error classification plus the request identifier used by support.
    case apiFailure(SonioxTTSFailure)
}

public enum SonioxTTSFailureType: Equatable, Sendable {
    case unauthenticated
    case invalidRequest
    case rateLimited
    case modelNotAvailable
    case voiceNotFound
    case voiceNotReady
    case internalError
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "unauthenticated", "authentication_error": self = .unauthenticated
        case "invalid_request": self = .invalidRequest
        case "rate_limited", "too_many_requests": self = .rateLimited
        case "model_not_available": self = .modelNotAvailable
        case "voice_not_found": self = .voiceNotFound
        case "voice_not_ready", "voice_not_computed": self = .voiceNotReady
        case "internal_error": self = .internalError
        case let value?: self = .unknown(value)
        case nil: self = .unknown("unknown")
        }
    }
}

public struct SonioxTTSFailure: Equatable, Sendable {
    public let statusCode: Int
    public let type: SonioxTTSFailureType
    public let message: String
    public let requestID: String?

    /// True when Soniox refused the credential.
    ///
    /// The status code is the fallback signal: a proxy or a future release can
    /// answer 401 or 403 with an unknown `error_type`, or with no error body at
    /// all, and the caller must still tell the user to check the key.
    public var isAuthenticationFailure: Bool {
        type == .unauthenticated || statusCode == 401 || statusCode == 403
    }
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
    public let accountVoice: SonioxTTSAccountVoice?
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
        self.language = SonioxTTSCatalog.requiredLanguageCode(language)
        self.voice = voice
        self.accountVoice = nil
        self.audioFormat = audioFormat
        self.sampleRate = sampleRate.flatMap { SonioxTTSAPI.supportedSampleRates.contains($0) ? $0 : nil }
        self.speed = min(max(speed, SonioxTTSAPI.speedRange.lowerBound), SonioxTTSAPI.speedRange.upperBound)
    }

    public init(
        model: SonioxTTSModel = SonioxTTSCatalog.defaultModel,
        language: String,
        accountVoice: SonioxTTSAccountVoice,
        audioFormat: SonioxTTSAudioFormat,
        sampleRate: Int? = nil,
        speed: Double = 1.0
    ) {
        self.model = model
        self.language = SonioxTTSCatalog.requiredLanguageCode(language)
        self.voice = SonioxTTSCatalog.defaultVoice(for: model)
        self.accountVoice = accountVoice
        self.audioFormat = audioFormat
        self.sampleRate = sampleRate.flatMap { SonioxTTSAPI.supportedSampleRates.contains($0) ? $0 : nil }
        self.speed = min(max(speed, SonioxTTSAPI.speedRange.lowerBound), SonioxTTSAPI.speedRange.upperBound)
    }

    public var apiVoiceID: String { accountVoice?.id ?? voice.apiVoiceName }

    func jsonBody(text: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "language": language,
            "voice": apiVoiceID,
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
    /// US compatibility alias. New callers should select a ``SonioxTTSRegion``.
    public static let speakEndpoint = SonioxTTSRegion.unitedStates.speakEndpoint
    /// US compatibility alias. New callers should select a ``SonioxTTSRegion``.
    public static let modelsEndpoint = SonioxTTSRegion.unitedStates.modelsEndpoint
    /// Soniox rejects requests above this length.
    public static let maxTextLength = 5000
    /// Safety bound for account-voice pagination.
    private static let maxVoicePages = 20
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
    public let region: SonioxTTSRegion

    public init(session: URLSession = .shared, region: SonioxTTSRegion = .unitedStates) {
        self.session = session
        self.region = region
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

        var urlRequest = URLRequest(url: region.speakEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request.jsonBody(text: text))

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonioxTTSAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SonioxTTSAPIError.apiFailure(Self.failure(from: data, statusCode: httpResponse.statusCode))
        }

        return data
    }

    /// Validates a Soniox API key against the TTS models endpoint.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "Empty API key")
        }

        var request = URLRequest(url: region.modelsEndpoint)
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

    /// Retrieves every project-owned cloned voice, following Soniox pagination.
    public func listAccountVoices(apiKey: String) async throws -> [SonioxTTSAccountVoice] {
        var voices: [SonioxTTSAccountVoice] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pageCount = 0

        repeat {
            guard pageCount < Self.maxVoicePages else { break }
            pageCount += 1
            guard var components = URLComponents(
                url: region.voicesEndpoint,
                resolvingAgainstBaseURL: false
            ) else {
                throw SonioxTTSAPIError.invalidResponse
            }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems
            guard let url = components.url else { throw SonioxTTSAPIError.invalidResponse }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SonioxTTSAPIError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw SonioxTTSAPIError.apiFailure(Self.failure(from: data, statusCode: response.statusCode))
            }

            let page = try JSONDecoder().decode(AccountVoicePage.self, from: data)
            voices.append(contentsOf: page.voices)
            if let nextCursor = page.nextPageCursor,
               !nextCursor.isEmpty,
               seenCursors.insert(nextCursor).inserted {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor?.isEmpty == false

        return voices
    }

    /// Soniox reports failures as JSON. Unknown payloads are deliberately not echoed,
    /// because a proxy response could contain submitted text or credentials.
    static func errorMessage(from data: Data) -> String {
        Self.failure(from: data, statusCode: 0).message
    }

    static func failure(from data: Data, statusCode: Int) -> SonioxTTSFailure {
        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        return SonioxTTSFailure(
            statusCode: statusCode,
            type: SonioxTTSFailureType(rawValue: payload?.errorType),
            message: payload?.errorMessage ?? payload?.message ?? "Unknown Soniox error",
            requestID: payload?.requestID
        )
    }
}

private struct AccountVoicePage: Decodable {
    let voices: [SonioxTTSAccountVoice]
    let nextPageCursor: String?

    enum CodingKeys: String, CodingKey {
        case voices
        case nextPageCursor = "next_page_cursor"
    }
}

private struct ErrorPayload: Decodable {
    let errorType: String?
    let errorMessage: String?
    let message: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case message
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }
}
