import Foundation

/// Errors surfaced by the shared Groq Orpheus speech-generation transport.
public enum GroqTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    case emptyText
    /// HTTP 401/403 — the key is missing, wrong or revoked.
    case unauthorized(statusCode: Int, message: String)
    /// The organisation has not accepted this model's terms. Groq returns HTTP
    /// 400 with `model_terms_required`; only a console admin can clear it, so
    /// it must never be reported as a bad key.
    case modelTermsRequired(message: String)
    /// The organisation or project blocks this model, or the account's spend
    /// limit is reached. Neither is fixable from the app.
    case accessBlocked(message: String)
    /// HTTP 429 — over the model's request or token allowance.
    case rateLimited(message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// One Groq speech-generation request.
public struct GroqTTSRequest: Equatable, Sendable {
    public let model: GroqTTSModel
    /// Orpheus voice persona id, without Speak's `groq/` routing prefix.
    public let voiceID: String

    /// - Parameter voiceID: Stored voice identifier, with or without the prefix.
    ///   The model is taken from the resolved voice: the two persona lists do
    ///   not overlap, so pairing a voice with the wrong model is a 400.
    public init(voiceID: String) {
        let voice = GroqTTSCatalog.resolvedVoice(forID: voiceID)
        self.model = voice.model
        self.voiceID = voice.apiVoiceID
    }

    public func jsonBody(input: String) -> [String: Any] {
        [
            "model": model.rawValue,
            "input": input,
            "voice": voiceID,
            // Groq documents WAV as the only format Orpheus returns. The
            // formats listed on the generic speech reference belong to the
            // retired PlayAI models.
            "response_format": GroqTTSAPI.responseFormat
        ]
    }
}

/// Shared Groq Orpheus text-to-speech transport.
///
/// Owns request construction, authentication and response classification only —
/// audio playback, chunk joining and cost accounting stay with each platform
/// caller. The API key travels solely in the `Authorization` header and is
/// never logged or embedded in errors.
public struct GroqTTSAPI: Sendable {
    /// OpenAI-compatible speech endpoint.
    public static let speechEndpoint =
        URL(string: "https://api.groq.com/openai/v1/audio/speech")!
    /// Model listing, used as the cheap key-validation probe.
    public static let modelsEndpoint =
        URL(string: "https://api.groq.com/openai/v1/models")!
    /// The only container Groq documents for Orpheus.
    public static let responseFormat = "wav"
    /// Groq caps one Orpheus request at 200 characters, so longer text is
    /// spoken as a sequence of requests and the audio joined.
    public static let maxInputCharacters = 200
    /// Most requests one synthesis may fan out into.
    ///
    /// Every chunk is a separate billable Orpheus request, a separate
    /// temporary file and a separate round trip, so a 200-character cap turns
    /// a pasted document into hundreds of charges with no warning. Sixty
    /// requests is about 12,000 characters — several minutes of speech — and
    /// anything longer is refused with an explanation rather than billed.
    public static let maxRequestsPerSynthesis = 60
    /// Longest text one synthesis accepts, derived from the request budget.
    public static var maxSynthesisCharacters: Int {
        maxInputCharacters * maxRequestsPerSynthesis
    }
    /// Where an organisation admin accepts a model's terms.
    public static let modelTermsURL = "https://console.groq.com/settings/model-terms"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// POSTs `input` to `/audio/speech` and returns the synthesized WAV bytes.
    public func synthesize(
        input: String,
        apiKey: String,
        request: GroqTTSRequest
    ) async throws -> Data {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroqTTSAPIError.emptyText
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
            throw GroqTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw GroqTTSAPIError.invalidResponse }
        return data
    }

    /// Validates a Groq API key with a `GET /models` probe.
    ///
    /// A valid key is not evidence of Orpheus access: model terms and
    /// organisation model permissions are settled per organisation in the
    /// console and only show up on the first synthesis request.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: Self.modelsEndpoint,
            headers: { key in ["Authorization": "Bearer \(key)"] },
            serviceName: "Groq",
            session: session,
            rejectionStatusCodes: [401, 403]
        ).validate(key)
    }

    /// Classifies a non-2xx response.
    ///
    /// Groq overloads HTTP 400: the machine-readable `code` separates a
    /// terms-acceptance gate and a spend block from an ordinary bad request,
    /// and each needs different advice.
    static func error(from data: Data, statusCode: Int) -> GroqTTSAPIError {
        let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let message = payload?.error.message ?? "Unknown Groq error"
        switch payload?.error.code {
        case "model_terms_required":
            return .modelTermsRequired(message: message)
        case "blocked_api_access",
             "model_permission_blocked_org",
             "model_permission_blocked_project":
            return .accessBlocked(message: message)
        default:
            break
        }
        switch statusCode {
        case 401:
            return .unauthorized(statusCode: statusCode, message: message)
        case 403:
            return .accessBlocked(message: message)
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let error: Body
}
