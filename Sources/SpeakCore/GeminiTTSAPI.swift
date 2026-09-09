import Foundation

/// Errors surfaced by the shared Gemini speech-generation transport.
public enum GeminiTTSAPIError: Error, Sendable, Equatable {
    case invalidResponse
    case emptyText
    /// No audio block came back. Gemini occasionally answers a speech request
    /// with text instead, which is a documented, retryable fault.
    case noAudioReturned(message: String)
    /// HTTP 401 (`authentication`) — the key is missing, invalid or expired.
    case unauthorized(statusCode: Int, message: String)
    /// HTTP 403 (`permission_denied`) — the key cannot reach this model.
    case permissionDenied(message: String)
    /// HTTP 429 (`rate_limit_exceeded`, `quota_exceeded`).
    case rateLimited(message: String)
    /// The request was refused by a content or language filter.
    case contentBlocked(code: String, message: String)
    /// Any other non-2xx response.
    case httpError(statusCode: Int, message: String)
}

/// The audio one Interactions step carried back.
public struct GeminiTTSAudio: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let sampleRate: Int
    public let channels: Int

    public init(data: Data, mimeType: String, sampleRate: Int, channels: Int) {
        self.data = data
        self.mimeType = mimeType
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Whether the bytes are already a self-describing container. Raw `L16`
    /// PCM needs a RIFF header before `AVAudioPlayer` will open it.
    public var isContainerised: Bool {
        !mimeType.lowercased().contains("l16")
    }

    /// Playable bytes: a container is passed through, raw PCM is wrapped.
    public var playableData: Data {
        guard !isContainerised else { return data }
        return PCMWaveWriter.wavData(
            pcm: data,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: 16
        )
    }
}

/// One Gemini speech-generation request.
public struct GeminiTTSRequest: Equatable, Sendable {
    public let model: GeminiTTSModel
    /// Prebuilt voice name, without Speak's `google/` routing prefix.
    public let voiceName: String
    /// BCP-47 tag, or `nil` to let Gemini detect the language from the text.
    public let languageTag: String?
    public let sampleRate: Int

    /// - Parameters:
    ///   - model: Speech model to synthesize with.
    ///   - voiceID: Stored voice identifier, with or without the `google/` prefix.
    ///   - languageIdentifier: The user's voice-output language preference
    ///     (`en_GB`, `automatic`, or `nil`). Only a regional choice is sent:
    ///     Gemini detects the language on its own and a base code alone adds
    ///     nothing.
    ///   - sampleRate: Requested output rate, in hertz.
    public init(
        model: GeminiTTSModel = GeminiTTSCatalog.defaultModel,
        voiceID: String,
        languageIdentifier: String? = nil,
        sampleRate: Int = GeminiTTSAPI.defaultSampleRate
    ) {
        self.model = model
        self.voiceName = GeminiTTSCatalog.resolvedVoice(forID: voiceID).apiVoiceName
        self.languageTag = Self.resolveLanguageTag(languageIdentifier)
        self.sampleRate = sampleRate
    }

    public func jsonBody(input: String) -> [String: Any] {
        var speechConfig: [String: Any] = ["voice": voiceName]
        if let languageTag {
            speechConfig["language"] = languageTag
        }
        return [
            "model": model.rawValue,
            "input": input,
            "response_format": ["type": "audio", "sample_rate": sampleRate],
            "generation_config": ["speech_config": [speechConfig]]
        ]
    }

    static func resolveLanguageTag(_ identifier: String?) -> String? {
        let normalized = VoiceOutputLanguageCatalog.normalizedIdentifier(identifier)
        guard normalized != VoiceOutputLanguageCatalog.automaticIdentifier else { return nil }
        let parts = normalized.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard parts.count >= 2 else { return nil }
        return "\(parts[0].lowercased())-\(parts[1].uppercased())"
    }
}

/// Shared Gemini text-to-speech transport, over the Interactions API.
///
/// Speak already reaches Gemini transcription through `/v1beta/interactions`,
/// and the speech-generation guide documents the same surface, so both
/// directions share one host, one header and one credential. Audio playback,
/// file handling and cost accounting stay with each platform caller.
public struct GeminiTTSAPI: Sendable {
    /// Interactions API endpoint, shared with Gemini transcription.
    public static let interactionsEndpoint = GeminiTranscribeModels.interactionsURL
    /// Header the Gemini API authenticates REST calls with.
    public static let apiKeyHeader = GeminiTranscribeModels.apiKeyHeader
    /// Gemini's samples write 24 kHz mono 16-bit PCM.
    public static let defaultSampleRate = 24_000
    /// A speech session is capped at a 32k-token context; 8,000 characters
    /// stays comfortably inside it, and longer text is spoken in parts.
    public static let maxInputCharacters = 8_000
    /// Gemini documents that a small share of speech requests fail with HTTP
    /// 500 because the model answered in text, and that callers should retry.
    public static let serverFaultRetries = 1

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Synthesizes `input` and returns the audio block from the response.
    public func synthesize(
        input: String,
        apiKey: String,
        request: GeminiTTSRequest
    ) async throws -> GeminiTTSAudio {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTTSAPIError.emptyText
        }

        var attempt = 0
        while true {
            do {
                return try await performSynthesis(input: input, apiKey: apiKey, request: request)
            } catch let error as GeminiTTSAPIError {
                guard Self.isRetryable(error), attempt < Self.serverFaultRetries else { throw error }
                attempt += 1
                try Task.checkCancellation()
            }
        }
    }

    /// Only the documented random text-token fault is retried. An auth,
    /// permission, quota or content decision would return the same answer.
    static func isRetryable(_ error: GeminiTTSAPIError) -> Bool {
        switch error {
        case .noAudioReturned:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500
        default:
            return false
        }
    }

    private func performSynthesis(
        input: String,
        apiKey: String,
        request: GeminiTTSRequest
    ) async throws -> GeminiTTSAudio {
        var urlRequest = URLRequest(url: Self.interactionsEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: request.jsonBody(input: input)
        )

        try Task.checkCancellation()
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiTTSAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        return try Self.audio(from: data, requestedSampleRate: request.sampleRate)
    }

    /// Extracts the first audio content block from an interaction response.
    static func audio(from data: Data, requestedSampleRate: Int) throws -> GeminiTTSAudio {
        guard let interaction = try? JSONDecoder().decode(InteractionResponse.self, from: data) else {
            throw GeminiTTSAPIError.invalidResponse
        }
        let blocks = (interaction.steps ?? []).flatMap { $0.content ?? [] }
        guard let audioBlock = blocks.first(where: { $0.type == "audio" }),
              let encoded = audioBlock.data,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty
        else {
            throw GeminiTTSAPIError.noAudioReturned(
                message: "Gemini returned no audio for this request"
            )
        }
        return GeminiTTSAudio(
            data: bytes,
            mimeType: audioBlock.mimeType ?? "audio/l16",
            sampleRate: audioBlock.sampleRate ?? requestedSampleRate,
            channels: audioBlock.channels ?? 1
        )
    }

    /// Validates a Gemini API key with a `ListModels` probe. The same key
    /// serves transcription and speech generation.
    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: GeminiTranscribeModels.listModelsURL,
            headers: { key in [Self.apiKeyHeader: key] },
            serviceName: GeminiTranscribeModels.providerDisplayName,
            session: session,
            rejectionStatusCodes: [400, 401, 403]
        ).validate(key)
    }

    /// Classifies a non-2xx response.
    ///
    /// The Interactions API returns a snake_case string `code`; the legacy
    /// `generateContent` envelope used an integer code with a `status` string.
    /// Both are accepted so a response from either surface is classified.
    static func error(from data: Data, statusCode: Int) -> GeminiTTSAPIError {
        let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let message = payload?.error.message ?? "Unknown Gemini error"
        let code = payload?.error.code?.stringValue ?? payload?.error.status ?? ""
        switch code.lowercased() {
        case "authentication", "api_key_invalid", "unauthenticated":
            return .unauthorized(statusCode: statusCode, message: message)
        case "permission_denied":
            return .permissionDenied(message: message)
        case "rate_limit_exceeded", "quota_exceeded", "too_many_requests", "resource_exhausted":
            return .rateLimited(message: message)
        case "safety", "recitation", "language", "prohibited_content", "spii",
             "blocklist", "content_blocked":
            return .contentBlocked(code: code, message: message)
        default:
            break
        }
        switch statusCode {
        case 401:
            return .unauthorized(statusCode: statusCode, message: message)
        case 403:
            return .permissionDenied(message: message)
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }
}

private struct InteractionResponse: Decodable {
    let steps: [InteractionStep]?
}

private struct InteractionStep: Decodable {
    let content: [InteractionBlock]?
}

private struct InteractionBlock: Decodable {
    let type: String?
    let data: String?
    let mimeType: String?
    let sampleRate: Int?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case mimeType = "mime_type"
        case sampleRate = "sample_rate"
        case channels
    }
}

/// Accepts the Interactions API's string `code` and the legacy integer one.
private enum ErrorCode: Decodable {
    case string(String)
    case number(Int)

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number: nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Int.self))
        }
    }
}

private struct ErrorBody: Decodable {
    let code: ErrorCode?
    let message: String?
    let status: String?
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
}
