import Foundation

/// Errors surfaced by the shared xAI speech-generation transports.
public enum XAITTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    case emptyText
    case textTooLong(limit: Int, characterCount: Int)
    /// HTTP 401/403 — the key is missing, wrong or revoked.
    case unauthorized(statusCode: Int, message: String)
    /// HTTP 402 — the account has no credit left. A stored key is not credit.
    case quotaExceeded(message: String)
    /// HTTP 404 — the named `voice_id` does not exist on this account.
    case voiceNotFound(message: String)
    /// HTTP 429 — too many requests.
    case rateLimited(message: String)
    case badRequest(message: String)
    case httpError(statusCode: Int, message: String)
}

/// Audio containers `POST /v1/tts` can return.
public enum XAITTSCodec: String, CaseIterable, Codable, Hashable, Sendable {
    case mp3
    case wav
    /// Headerless little-endian 16-bit PCM. Needs `PCMWaveWriter` before it
    /// can be handed to a file player.
    case pcm

    public var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .wav, .pcm: "wav"
        }
    }
}

/// One xAI speech request.
///
/// `language` is required by the API, so it always travels; `output_format`
/// carries the codec and, for MP3, the bit rate.
public struct XAITTSRequest: Equatable, Sendable {
    public let voiceID: String
    public let language: String
    public let codec: XAITTSCodec
    public let sampleRate: Int
    public let bitRate: Int
    public let speed: Double

    public init(
        voiceID: String,
        language: String?,
        codec: XAITTSCodec = .mp3,
        sampleRate: Int = XAITTSAPI.defaultSampleRate,
        bitRate: Int = XAITTSAPI.defaultBitRate,
        speed: Double = 1.0
    ) {
        self.voiceID = XAITTSCatalog.resolvedAPIVoiceID(forVoiceID: voiceID)
        self.language = XAITTSCatalog.languageTag(for: language)
        self.codec = codec
        self.sampleRate = XAITTSAPI.supportedSampleRates.contains(sampleRate)
            ? sampleRate
            : XAITTSAPI.defaultSampleRate
        self.bitRate = XAITTSAPI.supportedBitRates.contains(bitRate)
            ? bitRate
            : XAITTSAPI.defaultBitRate
        self.speed = min(max(speed, XAITTSAPI.speedRange.lowerBound), XAITTSAPI.speedRange.upperBound)
    }

    public func jsonBody(text: String) -> [String: Any] {
        var outputFormat: [String: Any] = [
            "codec": codec.rawValue,
            "sample_rate": sampleRate
        ]
        // `bit_rate` applies to MP3 only; sending it with WAV or PCM would be
        // a field the service has no use for.
        if codec == .mp3 { outputFormat["bit_rate"] = bitRate }
        return [
            "text": text,
            "voice_id": voiceID,
            "language": language,
            "output_format": outputFormat,
            "speed": speed
        ]
    }
}

/// Shared xAI text-to-speech transport.
///
/// Owns URL construction, authentication and response classification only.
/// The API key travels solely in the `Authorization` header and is never logged
/// or embedded in an error.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
/// (read 2026-09-10).
public struct XAITTSAPI: Sendable {
    public static let speechEndpoint = URL(string: "https://api.x.ai/v1/tts")!
    public static let voicesEndpoint = URL(string: "https://api.x.ai/v1/tts/voices")!

    /// One request accepts at most 15,000 characters of text.
    public static let maximumTextCharacters = 15_000
    public static let speedRange: ClosedRange<Double> = 0.7...1.5
    public static let supportedSampleRates: Set<Int> = [
        8_000, 16_000, 22_050, 24_000, 44_100, 48_000
    ]
    public static let supportedBitRates: Set<Int> = [32_000, 64_000, 96_000, 128_000, 192_000]
    public static let defaultSampleRate = 24_000
    public static let defaultBitRate = 128_000

    /// $15.00 per 1M characters of submitted text.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.015")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Synthesizes `text` and returns the audio bytes in the requested codec.
    public func synthesize(
        text: String,
        apiKey: String,
        request: XAITTSRequest
    ) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XAITTSAPIError.emptyText
        }
        guard text.count <= Self.maximumTextCharacters else {
            throw XAITTSAPIError.textTooLong(
                limit: Self.maximumTextCharacters,
                characterCount: text.count
            )
        }

        var urlRequest = URLRequest(url: Self.speechEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: request.jsonBody(text: text)
        )

        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XAITTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw XAITTSAPIError.invalidResponse }
        return data
    }

    /// `GET /v1/tts/voices` — the account's own voice list, which is where the
    /// voices beyond the two documented presets come from.
    public func listVoices(apiKey: String) async throws -> [XAITTSVoice] {
        var request = URLRequest(url: Self.voicesEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XAITTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        return try Self.decodeVoices(data)
    }

    static func decodeVoices(_ data: Data) throws -> [XAITTSVoice] {
        guard let payload = try? JSONDecoder().decode(XAIVoiceListPayload.self, from: data) else {
            throw XAITTSAPIError.invalidResponse
        }
        return payload.voices.map {
            XAITTSVoice(
                id: $0.voiceID,
                name: $0.name ?? $0.voiceID.capitalized,
                language: $0.language
            )
        }
    }

    /// Validates the account key against the voices listing.
    ///
    /// That proves the key is live and can reach the speech routes. It is not
    /// evidence of remaining credit, which xAI exposes no probe for.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: Self.voicesEndpoint,
            headers: { key in ["Authorization": "Bearer \(key)"] },
            serviceName: "xAI",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    static func error(from data: Data, statusCode: Int) -> XAITTSAPIError {
        let message = XAISpeechToTextError.message(from: data)
        switch statusCode {
        case 400:
            return .badRequest(message: message)
        case 401, 403:
            return .unauthorized(statusCode: statusCode, message: message)
        case 402:
            return .quotaExceeded(message: message)
        case 404:
            return .voiceNotFound(message: message)
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }
}

private struct XAIVoiceListPayload: Decodable {
    let voices: [XAIVoiceListEntry]
}

private struct XAIVoiceListEntry: Decodable {
    let voiceID: String
    let name: String?
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case language
    }
}
