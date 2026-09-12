import Foundation

/// Errors surfaced by the shared Cartesia Sonic speech-generation transport.
///
/// Each platform client maps these onto its own error type so existing
/// user-facing behaviour is preserved.
public enum CartesiaTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    /// HTTP 401/403 — the key is missing, wrong or revoked.
    case unauthorized(statusCode: Int, message: String)
    /// HTTP 402 — the account is out of credits.
    case quotaExceeded(message: String)
    /// HTTP 429 — too many requests for the current plan.
    case rateLimited(message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// Audio containers Cartesia can return from `/tts/bytes`.
public enum CartesiaTTSContainer: String, Codable, Hashable, Sendable {
    case wav
    case mp3
    case raw
}

/// Sample encodings Cartesia accepts for the `wav` and `raw` containers.
public enum CartesiaTTSEncoding: String, Codable, Hashable, Sendable {
    case pcmS16LE = "pcm_s16le"
    case pcmF32LE = "pcm_f32le"
    case pcmMuLaw = "pcm_mulaw"
    case pcmALaw = "pcm_alaw"
}

/// The `output_format` object of a Cartesia speech request.
///
/// `encoding` belongs to the sample-based containers and `bit_rate` to MP3;
/// sending the wrong pairing is a 400, so the two factory methods are the only
/// supported ways to build one.
public struct CartesiaTTSOutputFormat: Equatable, Sendable {
    public let container: CartesiaTTSContainer
    public let encoding: CartesiaTTSEncoding?
    public let sampleRate: Int
    public let bitRate: Int?

    private init(
        container: CartesiaTTSContainer,
        encoding: CartesiaTTSEncoding?,
        sampleRate: Int,
        bitRate: Int?
    ) {
        self.container = container
        self.encoding = encoding
        self.sampleRate = CartesiaTTSAPI.supportedSampleRate(nearest: sampleRate)
        self.bitRate = bitRate
    }

    /// A RIFF/WAV file of 16-bit little-endian samples — what `AVAudioPlayer`
    /// opens with no re-encoding.
    public static func wav(sampleRate: Int) -> CartesiaTTSOutputFormat {
        CartesiaTTSOutputFormat(
            container: .wav,
            encoding: .pcmS16LE,
            sampleRate: sampleRate,
            bitRate: nil
        )
    }

    public static func mp3(sampleRate: Int, bitRate: Int = 128_000) -> CartesiaTTSOutputFormat {
        CartesiaTTSOutputFormat(
            container: .mp3,
            encoding: nil,
            sampleRate: sampleRate,
            bitRate: bitRate
        )
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "container": container.rawValue,
            "sample_rate": sampleRate
        ]
        if let encoding {
            object["encoding"] = encoding.rawValue
        }
        if let bitRate {
            object["bit_rate"] = bitRate
        }
        return object
    }
}

/// One Cartesia speech-generation request, with the documented limits applied on
/// construction so callers cannot build an out-of-range request.
public struct CartesiaTTSRequest: Equatable, Sendable {
    public let model: CartesiaTTSModel
    /// Cartesia voice UUID, without Speak's `cartesia/` routing prefix.
    public let voiceID: String
    public let outputFormat: CartesiaTTSOutputFormat
    /// Base ISO language code, for example `en`. Mutually exclusive with ``locale``.
    public let language: String?
    /// Language-region pair, for example `en-GB`. Mutually exclusive with ``language``.
    public let locale: String?
    /// Speaking rate, clamped to the range Cartesia accepts.
    public let speed: Double

    /// - Parameters:
    ///   - model: Sonic model to synthesize with.
    ///   - voiceID: Stored voice identifier, with or without the `cartesia/` prefix.
    ///   - outputFormat: Container, encoding and sample rate of the returned audio.
    ///   - languageIdentifier: The user's voice-output language preference
    ///     (`en_GB`, `automatic`, or `nil`). A regional choice becomes `locale`
    ///     on a model that supports it and the base language code otherwise.
    ///   - content: Text being spoken, used to resolve `Automatic`.
    ///   - speed: Requested rate, clamped into ``CartesiaTTSAPI/speedRange``.
    public init(
        model: CartesiaTTSModel = CartesiaTTSCatalog.defaultModel,
        voiceID: String,
        outputFormat: CartesiaTTSOutputFormat,
        languageIdentifier: String?,
        content: String = "",
        speed: Double = 1.0
    ) {
        self.model = model
        self.voiceID = CartesiaTTSCatalog.resolvedAPIVoiceID(forVoiceID: voiceID)
        self.outputFormat = outputFormat
        let resolved = Self.resolveLanguage(
            identifier: languageIdentifier,
            content: content,
            model: model
        )
        self.language = resolved.language
        self.locale = resolved.locale
        self.speed = min(
            max(speed, CartesiaTTSAPI.speedRange.lowerBound),
            CartesiaTTSAPI.speedRange.upperBound
        )
    }

    public func jsonBody(transcript: String) -> [String: Any] {
        var body: [String: Any] = [
            "model_id": model.rawValue,
            "transcript": transcript,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": outputFormat.jsonObject,
            "generation_config": ["speed": speed]
        ]
        // `language` and `locale` are mutually exclusive; the resolver only ever
        // produces one of them.
        if let locale {
            body["locale"] = locale
        } else if let language {
            body["language"] = language
        }
        return body
    }

    private static func resolveLanguage(
        identifier: String?,
        content: String,
        model: CartesiaTTSModel
    ) -> (language: String?, locale: String?) {
        let normalized = VoiceOutputLanguageCatalog.normalizedIdentifier(identifier)
        let baseCode = VoiceOutputLanguageCatalog.languageCode(for: identifier, content: content)

        guard normalized != VoiceOutputLanguageCatalog.automaticIdentifier else {
            return (baseCode, nil)
        }

        let parts = normalized.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard model.supportsLocale, parts.count >= 2 else {
            return (baseCode, nil)
        }
        return (nil, "\(parts[0].lowercased())-\(parts[1].uppercased())")
    }
}

/// Shared Cartesia Sonic text-to-speech transport.
///
/// Owns request construction, authentication headers and response
/// classification only — audio playback, file handling and cost accounting stay
/// with each platform caller. The API key travels solely in the `Authorization`
/// header and is never logged or embedded in errors.
public struct CartesiaTTSAPI: Sendable {
    /// Synthesis endpoint. Returns raw audio bytes in the requested container.
    public static let bytesEndpoint = URL(string: "https://api.cartesia.ai/tts/bytes")!
    /// Voice library endpoint, also used as the cheap key-validation probe.
    public static let voicesEndpoint = URL(string: "https://api.cartesia.ai/voices")!
    /// Cartesia dates its API; the header is required on every request.
    public static let apiVersion = "2026-08-14"
    public static let versionHeaderField = "Cartesia-Version"
    /// Speaking rates Cartesia accepts in `generation_config.speed`.
    public static let speedRange: ClosedRange<Double> = 0.6...1.5
    /// Output sample rates Cartesia accepts.
    public static let supportedSampleRates: [Int] = [8000, 16_000, 22_050, 24_000, 44_100, 48_000]
    /// Cartesia bills text-to-speech at one credit per character. The Startup
    /// plan buys 1,250,000 credits for $49, so a thousand characters costs about
    /// $0.0392. Used for the pre-synthesis estimate only.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.0392")!
    /// Safety bound for voice-library pagination.
    private static let maxVoicePages = 20
    private static let voicePageSize = 100

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Snaps a requested sample rate onto the nearest value Cartesia supports.
    public static func supportedSampleRate(nearest sampleRate: Int) -> Int {
        supportedSampleRates.contains(sampleRate)
            ? sampleRate
            : supportedSampleRates.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            }) ?? 24_000
    }

    /// POSTs `transcript` to `/tts/bytes` and returns the synthesized audio bytes.
    ///
    /// - Parameters:
    ///   - transcript: Text to speak.
    ///   - apiKey: Cartesia API key (`sk_car_…`), sent as `Bearer` authorization.
    ///   - request: Model, voice, language and output settings.
    public func synthesize(
        transcript: String,
        apiKey: String,
        request: CartesiaTTSRequest
    ) async throws -> Data {
        var urlRequest = URLRequest(url: Self.bytesEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: Self.versionHeaderField)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: request.jsonBody(transcript: transcript)
        )

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CartesiaTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        return data
    }

    /// Validates a Cartesia API key with a one-voice `GET /voices` probe.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        var components = URLComponents(url: Self.voicesEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        let url = components?.url ?? Self.voicesEndpoint

        return await GETProbeAPIKeyValidator(
            url: url,
            headers: { key in
                [
                    "Authorization": "Bearer \(key)",
                    Self.versionHeaderField: Self.apiVersion
                ]
            },
            serviceName: "Cartesia",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    /// Retrieves the voice library visible to `apiKey`, following Cartesia's
    /// cursor pagination.
    public func listVoices(apiKey: String) async throws -> [CartesiaRemoteVoice] {
        var voices: [CartesiaRemoteVoice] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pageCount = 0

        repeat {
            guard pageCount < Self.maxVoicePages else { break }
            pageCount += 1

            guard var components = URLComponents(
                url: Self.voicesEndpoint,
                resolvingAgainstBaseURL: false
            ) else {
                throw CartesiaTTSAPIError.invalidResponse
            }
            var queryItems = [URLQueryItem(name: "limit", value: String(Self.voicePageSize))]
            if let cursor {
                queryItems.append(URLQueryItem(name: "starting_after", value: cursor))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw CartesiaTTSAPIError.invalidResponse }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.apiVersion, forHTTPHeaderField: Self.versionHeaderField)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CartesiaTTSAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw Self.error(from: data, statusCode: httpResponse.statusCode)
            }

            let page = try JSONDecoder().decode(VoicePage.self, from: data)
            voices.append(contentsOf: page.data)
            if page.hasMore == true,
               let nextCursor = page.nextPage ?? page.data.last?.id,
               !nextCursor.isEmpty,
               seenCursors.insert(nextCursor).inserted {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return voices
    }

    /// Classifies a non-2xx response.
    ///
    /// Unknown payloads are deliberately not echoed verbatim, because a proxy
    /// response could contain submitted text or credentials.
    static func error(from data: Data, statusCode: Int) -> CartesiaTTSAPIError {
        let message = errorMessage(from: data)
        switch statusCode {
        case 401, 403:
            return .unauthorized(statusCode: statusCode, message: message)
        case 402:
            return .quotaExceeded(message: message)
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }

    static func errorMessage(from data: Data) -> String {
        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        return payload?.error ?? payload?.message ?? "Unknown Cartesia error"
    }
}

private struct VoicePage: Decodable {
    let data: [CartesiaRemoteVoice]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct ErrorPayload: Decodable {
    let error: String?
    let message: String?
}
