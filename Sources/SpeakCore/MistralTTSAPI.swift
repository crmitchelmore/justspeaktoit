import Foundation

/// Errors surfaced by the shared Mistral Voxtral speech-generation transport.
public enum MistralTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    case emptyText
    /// No voice was chosen. Mistral has no default voice: `voice_id` names a
    /// preset or a cloned voice, and the account's list is the only source.
    case voiceRequired
    /// HTTP 401 — the key is missing, invalid, expired or from another workspace.
    case unauthorized(statusCode: Int, message: String)
    /// HTTP 403. Mistral overloads this for both a subscription tier that does
    /// not include the model and a moderation rejection of the submitted text,
    /// so the two are reported together rather than guessed apart.
    case forbidden(message: String)
    /// HTTP 429 — over the tier's request or token allowance.
    case rateLimited(message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// Audio containers `/v1/audio/speech` can return.
///
/// `pcm` is documented as raw float32 little-endian samples rather than the
/// int16 the platform audio paths expect, so it is deliberately not offered.
public enum MistralTTSResponseFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case mp3
    case wav
    case flac
    case opus
}

/// One Mistral speech-generation request.
public struct MistralTTSRequest: Equatable, Sendable {
    public let model: MistralTTSModel
    /// Mistral voice UUID, without Speak's `mistral/` routing prefix.
    public let voiceID: String
    public let responseFormat: MistralTTSResponseFormat

    public init(
        model: MistralTTSModel = MistralTTSCatalog.defaultModel,
        voiceID: String,
        responseFormat: MistralTTSResponseFormat = .mp3
    ) {
        self.model = model
        self.voiceID = MistralTTSCatalog.apiVoiceID(forVoiceID: voiceID)
        self.responseFormat = responseFormat
    }

    public func jsonBody(input: String) -> [String: Any] {
        [
            "model": model.rawValue,
            "input": input,
            "voice_id": voiceID,
            "response_format": responseFormat.rawValue,
            // The macOS voice pipeline plays a finished file, so the
            // server-sent-events variant has nothing to feed.
            "stream": false
        ]
    }
}

/// Shared Mistral Voxtral text-to-speech transport.
///
/// Owns request construction, authentication and response classification only.
/// The API key travels solely in the `Authorization` header and is never logged
/// or embedded in an error.
public struct MistralTTSAPI: Sendable {
    public static let speechEndpoint =
        URL(string: "https://api.mistral.ai/v1/audio/speech")!
    /// Voice library endpoint, also used as the key-validation probe.
    public static let voicesEndpoint =
        URL(string: "https://api.mistral.ai/v1/audio/voices")!
    /// Mistral bills Voxtral TTS at $16 per million output characters.
    public static let estimatedCostPerThousandCharacters = Decimal(string: "0.016")!
    /// Mistral publishes no hard input cap, only the guidance that prompts stay
    /// under 300 words. 1,800 characters is a conservative reading of that, so
    /// longer text is spoken as a sequence of requests.
    public static let maxInputCharacters = 1_800
    private static let voicePageSize = 100

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// POSTs `input` to `/v1/audio/speech` and returns the decoded audio bytes.
    ///
    /// The non-streaming response is JSON carrying base64, not raw audio.
    public func synthesize(
        input: String,
        apiKey: String,
        request: MistralTTSRequest
    ) async throws -> Data {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MistralTTSAPIError.emptyText
        }
        guard !request.voiceID.isEmpty else {
            throw MistralTTSAPIError.voiceRequired
        }

        var urlRequest = URLRequest(url: Self.speechEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: request.jsonBody(input: input)
        )

        try Task.checkCancellation()
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(SpeechResponse.self, from: data),
              let audio = Data(base64Encoded: payload.audioData),
              !audio.isEmpty
        else {
            throw MistralTTSAPIError.invalidResponse
        }
        return audio
    }

    /// Lists the voices `apiKey` can use.
    ///
    /// - Parameter presetsOnly: Restrict to Mistral's own presets. Cloned
    ///   voices belong to the account that made them and are included when this
    ///   is `false`.
    public func listVoices(apiKey: String, presetsOnly: Bool = false) async throws -> [MistralTTSVoice] {
        guard var components = URLComponents(
            url: Self.voicesEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw MistralTTSAPIError.invalidResponse
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(Self.voicePageSize))]
        if presetsOnly {
            queryItems.append(URLQueryItem(name: "type", value: "preset"))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw MistralTTSAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        return try Self.decodeVoices(from: data)
    }

    /// Validates a Mistral API key with a one-voice listing probe.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        var components = URLComponents(url: Self.voicesEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        let url = components?.url ?? Self.voicesEndpoint

        return await GETProbeAPIKeyValidator(
            url: url,
            headers: { key in ["Authorization": "Bearer \(key)"] },
            serviceName: "Mistral",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    /// The listing envelope is not documented, so the two conventional shapes
    /// and a bare array are all accepted.
    static func decodeVoices(from data: Data) throws -> [MistralTTSVoice] {
        let decoder = JSONDecoder()
        if let page = try? decoder.decode(VoicePage.self, from: data) {
            return page.data ?? page.voices ?? []
        }
        if let voices = try? decoder.decode([MistralTTSVoice].self, from: data) {
            return voices
        }
        throw MistralTTSAPIError.invalidResponse
    }

    static func error(from data: Data, statusCode: Int) -> MistralTTSAPIError {
        let message = errorMessage(from: data)
        switch statusCode {
        case 401:
            return .unauthorized(statusCode: statusCode, message: message)
        case 403:
            return .forbidden(message: message)
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }

    /// Reads the documented error envelope. An undecodable body is not echoed
    /// verbatim: it could carry submitted text or a credential.
    static func errorMessage(from data: Data) -> String {
        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        return payload?.message ?? payload?.detail ?? "Unknown Mistral error"
    }
}

private struct SpeechResponse: Decodable {
    let audioData: String

    enum CodingKeys: String, CodingKey {
        case audioData = "audio_data"
    }
}

private struct VoicePage: Decodable {
    let data: [MistralTTSVoice]?
    let voices: [MistralTTSVoice]?
}

private struct ErrorPayload: Decodable {
    let message: String?
    let detail: String?
}
