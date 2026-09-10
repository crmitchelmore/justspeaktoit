import Foundation

/// Errors surfaced by the shared Speechmatics text-to-speech transport.
public enum SpeechmaticsTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    case emptyText
    /// HTTP 401/403 — the key is missing, wrong, revoked or not scoped to this project.
    case unauthorized(statusCode: Int, message: String)
    /// HTTP 402 — the account has no credit left.
    case quotaExceeded(message: String)
    /// HTTP 429 — too many requests.
    case rateLimited(message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// Audio the `/generate` endpoint can return.
///
/// `wav_16000` is the service default and the only one that plays without
/// further work; `pcm_16000` is the same samples with no RIFF header.
public enum SpeechmaticsTTSOutputFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case wav16k = "wav_16000"
    case pcm16k = "pcm_16000"

    public var sampleRate: Int { 16_000 }
}

/// One Speechmatics speech request. The voice is a path segment and the output
/// format a query item, so only the text travels in the body.
public struct SpeechmaticsTTSRequest: Equatable, Sendable {
    public let voiceID: String
    public let outputFormat: SpeechmaticsTTSOutputFormat

    /// - Parameters:
    ///   - voiceID: Stored voice identifier, with or without the `speechmatics/` prefix.
    ///   - outputFormat: Container of the returned audio.
    public init(
        voiceID: String,
        outputFormat: SpeechmaticsTTSOutputFormat = .wav16k
    ) {
        self.voiceID = SpeechmaticsTTSCatalog.resolvedAPIVoiceID(forVoiceID: voiceID)
        self.outputFormat = outputFormat
    }

    public func jsonBody(text: String) -> [String: Any] {
        ["text": text]
    }
}

/// Shared Speechmatics text-to-speech transport.
///
/// Owns URL construction, authentication and response classification only.
/// The API key travels solely in the `Authorization` header and is never
/// logged or embedded in an error.
///
/// Speechmatics serves speech generation from a single global `preview.` host
/// with no regional variants, so the region choice that applies to their
/// transcription endpoints has no equivalent here.
public struct SpeechmaticsTTSAPI: Sendable {
    public static let host = "preview.tts.speechmatics.com"
    /// Transcription endpoint reused as the key probe: Speechmatics publishes no
    /// GET endpoint on the speech host, and one portal key covers both products.
    public static let keyProbeEndpoint =
        URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs")!
    /// Speechmatics bills speech generation at $0.011 per 1,000 characters on
    /// the Pro plan. Used for the pre-synthesis estimate only.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.011")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `POST /generate/<voice>?output_format=<format>`.
    public static func generateURL(request: SpeechmaticsTTSRequest) -> URL? {
        guard let encodedVoice = request.voiceID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/generate/\(encodedVoice)"
        components.queryItems = [
            URLQueryItem(name: "output_format", value: request.outputFormat.rawValue)
        ]
        return components.url
    }

    /// Synthesizes `text` and returns the audio bytes in the requested container.
    public func synthesize(
        text: String,
        apiKey: String,
        request: SpeechmaticsTTSRequest
    ) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechmaticsTTSAPIError.emptyText
        }
        guard let url = Self.generateURL(request: request) else {
            throw SpeechmaticsTTSAPIError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: request.jsonBody(text: text)
        )

        try Task.checkCancellation()
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechmaticsTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw SpeechmaticsTTSAPIError.invalidResponse }
        return data
    }

    /// Validates the account key against the transcription jobs endpoint.
    ///
    /// This proves the key is live; it is not evidence of a speech-generation
    /// entitlement, which Speechmatics does not expose a probe for.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        var components = URLComponents(url: Self.keyProbeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        let url = components?.url ?? Self.keyProbeEndpoint

        return await GETProbeAPIKeyValidator(
            url: url,
            headers: { key in ["Authorization": "Bearer \(key)"] },
            serviceName: "Speechmatics",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    static func error(from data: Data, statusCode: Int) -> SpeechmaticsTTSAPIError {
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

    /// The speech host rejects at its edge proxy and returns an HTML body on
    /// 401, so a failed decode is expected rather than exceptional. Nothing is
    /// echoed verbatim: the body could carry submitted text or a credential.
    static func errorMessage(from data: Data) -> String {
        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        return payload?.error ?? payload?.detail ?? payload?.message ?? "Unknown Speechmatics error"
    }
}

private struct ErrorPayload: Decodable {
    let error: String?
    let detail: String?
    let message: String?
}
