import Foundation

/// Canonical identifiers, limits and prices for xAI's dedicated speech-to-text
/// service.
///
/// This is a different product from the Grok Voice realtime route in
/// `XAIVoiceModels`: it has its own REST and WebSocket endpoints, and xAI
/// publishes **no model identifier** for it — neither request accepts a `model`
/// field, and the models page lists it as the capability "Speech to Text"
/// rather than as a named model. The catalogue identifiers below are therefore
/// named after the capability, so the app never advertises a model id that does
/// not exist.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
/// (read 2026-09-10).
public enum XAISpeechToText {
    /// Batch (file upload) catalogue identifier.
    public static let batchCatalogID = "xai/speech-to-text"
    /// Realtime (WebSocket) catalogue identifier.
    public static let liveCatalogID = "xai/speech-to-text-streaming"

    public static let restEndpoint = URL(string: "https://api.x.ai/v1/stt")!
    static let webSocketHost = "api.x.ai"
    static let webSocketPath = "/v1/stt"

    /// Sample rates the service accepts for raw PCM in either direction.
    public static let supportedSampleRates: Set<Int> = [
        8_000, 16_000, 22_050, 24_000, 44_100, 48_000
    ]

    /// One uploaded file may not exceed 500 MB.
    public static let maximumUploadBytes = 500 * 1_000 * 1_000

    /// At most 100 keyterms of at most 50 characters each.
    public static let maximumKeyterms = 100
    public static let maximumKeytermCharacters = 50

    /// $0.10 per hour of audio over REST, $0.20 per hour streaming.
    public static let restCostPerHourOfAudio = Decimal(string: "0.10")!
    public static let streamingCostPerHourOfAudio = Decimal(string: "0.20")!

    /// The 25 languages the documentation lists. Used to decide whether a
    /// `language` (and therefore inverse text normalisation) can be requested;
    /// with no language the service still transcribes and reports what it
    /// detected.
    public static let supportedLanguageCodes: Set<String> = [
        "ar", "cs", "da", "de", "en", "es", "fa", "fil", "fr", "hi", "id", "it",
        "ja", "ko", "mk", "ms", "nl", "pl", "pt", "ro", "ru", "sv", "th", "tr", "vi"
    ]

    /// Containers the REST endpoint detects from the bytes, mapped to the MIME
    /// type the multipart part declares.
    static let containerMIMETypes: [String: String] = [
        "aac": "audio/aac", "flac": "audio/flac", "m4a": "audio/mp4",
        "mka": "audio/x-matroska", "mkv": "video/x-matroska", "mp3": "audio/mpeg",
        "mp4": "audio/mp4", "oga": "audio/ogg", "ogg": "audio/ogg",
        "opus": "audio/opus", "wav": "audio/wav"
    ]

    /// Resolves a Speak language selection (`en_GB`, `Automatic`, `nil`) to a
    /// code the service documents, or `nil` when it cannot be served.
    ///
    /// Returning `nil` is not a failure: the request simply omits `language`,
    /// and xAI detects and reports the language it heard.
    public static func languageCode(for selection: String?) -> String? {
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty, trimmed != "automatic", trimmed != "auto" else { return nil }
        guard let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else {
            return nil
        }
        let code = String(primary)
        return supportedLanguageCodes.contains(code) ? code : nil
    }

    /// Trims a keyword list to the documented bias limits.
    public static func boundedKeyterms(_ keywords: [String]) -> [String] {
        keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maximumKeytermCharacters }
            .prefix(maximumKeyterms)
            .map { $0 }
    }
}

/// Failures the shared xAI speech-to-text transports report.
///
/// The status code decides the case, so a revoked key points the user at
/// Settings and an exhausted balance does not. Nothing echoes a credential.
public enum XAISpeechToTextError: LocalizedError, Equatable {
    case unsupportedAudioFormat(String)
    case fileTooLarge
    case emptyTranscript
    case invalidResponse
    /// HTTP 401/403 — missing, wrong or revoked key.
    case unauthorized(statusCode: Int)
    /// HTTP 402 — the account has no credit left. A stored key is not credit.
    case quotaExceeded(message: String)
    /// HTTP 429 — too many requests.
    case rateLimited(message: String)
    case badRequest(message: String)
    case httpError(statusCode: Int, message: String)
    case server(message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat(let extensionName):
            return "xAI speech-to-text cannot read a .\(extensionName) recording. "
                + "It accepts WAV, MP3, Ogg, Opus, FLAC, AAC, MP4, M4A or MKV."
        case .fileTooLarge:
            return "The recording is larger than the 500 MB xAI speech-to-text accepts."
        case .emptyTranscript:
            return "xAI speech-to-text found no speech in the recording."
        case .invalidResponse:
            return "xAI speech-to-text returned a response Speak could not read."
        case .unauthorized(let statusCode):
            return "xAI rejected the API key (HTTP \(statusCode)). Check it in Settings."
        case .quotaExceeded(let message):
            return "xAI credit exhausted: \(message)"
        case .rateLimited(let message):
            return "xAI rate limit reached: \(message)"
        case .badRequest(let message):
            return "xAI rejected the speech-to-text request: \(message)"
        case .httpError(let statusCode, let message):
            return "xAI speech-to-text failed with HTTP \(statusCode): \(message)"
        case .server(let message):
            return "xAI speech-to-text failed: \(message)"
        }
    }

    /// Classifies a non-2xx REST response. The body is decoded for a message
    /// and never echoed verbatim, because it can carry submitted content.
    static func classify(statusCode: Int, body: Data) -> XAISpeechToTextError {
        let message = Self.message(from: body)
        switch statusCode {
        case 400:
            return .badRequest(message: message)
        case 401, 403:
            return .unauthorized(statusCode: statusCode)
        case 402:
            return .quotaExceeded(message: message)
        case 413:
            return .fileTooLarge
        case 429:
            return .rateLimited(message: message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }

    /// xAI returns `error` as a string on some routes and as an object with a
    /// `message` on others, so the body is read untyped rather than through one
    /// `Decodable` that the other shape would fail.
    static func message(from body: Data) -> String {
        let fallback = "Unknown xAI speech-to-text error"
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return fallback
        }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        for key in ["message", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return fallback
    }
}
