import Foundation

// MARK: - Gemini Live API wire protocol
//
// Pure request/response shaping for the Gemini Live API's
// `BidiGenerateContent` WebSocket, kept separate from the client so every frame
// and every event shape is testable without a socket.
//
// Docs: https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
//       https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket
//       https://ai.google.dev/api/live

/// One transcription update decoded from a `serverContent` message.
public struct GeminiLiveTranscriptEvent: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// A non-transcript server message the client has to react to.
public enum GeminiLiveServerSignal: Equatable, Sendable {
    /// The setup handshake completed; buffered audio may now be sent.
    case setupComplete
    /// The model finished the current turn.
    case turnComplete
    /// The server is about to close the connection.
    case goAway
    /// An error envelope, already mapped to a user-facing message.
    case failure(code: Int?, status: String?, message: String)
}

public extension GeminiLiveClient {
    // MARK: - Connection

    /// The Live API authenticates the WebSocket handshake with a `key` query
    /// parameter; there is no header form. The key therefore never reaches a
    /// log: `SensitiveHeaderRedactor` already redacts the `key` query item.
    static func webSocketURL(apiKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = GeminiTranscribeModels.apiHost
        components.path =
            "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: trimmed)]
        return components.url
    }

    // MARK: - Client messages

    /// The first frame after the socket opens. `languageCodes: []` is the
    /// documented "detect automatically and allow code-switching" setting.
    static func setupMessageJSON(
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String?,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> String? {
        var transcription: [String: Any] = [
            "languageCodes": GeminiTranscribeModels.languageCodes(from: language),
            "mode": mode.liveWireValue
        ]
        let vocabulary = GeminiTranscribeModels.boundedCustomVocabulary(customVocabulary)
        if !vocabulary.isEmpty {
            transcription["customVocabulary"] = vocabulary
        }

        let payload: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
                // Server-side voice activity detection owns turn boundaries;
                // the app pushes audio continuously and never barges in.
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": false]
                ]
            ]
        ]
        return Self.encode(payload)
    }

    /// One chunk of linear16 mono PCM, base64-encoded as the WebSocket
    /// transport requires.
    static func audioChunkJSON(_ audio: Data, sampleRate: Int) -> String? {
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": audio.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=\(sampleRate)"
                ]
            ]
        ]
        return Self.encode(payload)
    }

    /// Signals that no more audio is coming, so the server finalises the turn.
    static func audioStreamEndJSON() -> String {
        #"{"realtimeInput":{"audioStreamEnd":true}}"#
    }

    // MARK: - Server messages

    /// Decodes a transcription update, or `nil` when the message carries none.
    ///
    /// `interimInputTranscription` is the low-latency hypothesis for the
    /// utterance in flight; `inputTranscription` is the authoritative text for
    /// a finished utterance, which is why the client's `finalShape` is
    /// `.standaloneSegments`.
    static func transcriptEvent(from json: String) -> GeminiLiveTranscriptEvent? {
        guard let content = Self.decodeServerMessage(json)?.serverContent else { return nil }
        if let final = content.inputTranscription?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines), !final.isEmpty {
            return GeminiLiveTranscriptEvent(text: final, isFinal: true)
        }
        if let interim = content.interimInputTranscription?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines), !interim.isEmpty {
            return GeminiLiveTranscriptEvent(text: interim, isFinal: false)
        }
        return nil
    }

    /// Decodes the non-transcript signals the client reacts to.
    static func serverSignal(from json: String) -> GeminiLiveServerSignal? {
        guard let message = Self.decodeServerMessage(json) else { return nil }
        if let error = message.error {
            return .failure(
                code: error.code,
                status: error.status,
                message: error.message ?? "Gemini Live transcription failed"
            )
        }
        if message.setupComplete != nil { return .setupComplete }
        if message.goAway != nil { return .goAway }
        if message.serverContent?.turnComplete == true { return .turnComplete }
        return nil
    }

    /// Maps a Gemini error envelope onto the app's shared streaming errors.
    /// Auth failures become `StreamingClientError.invalidAPIKey` so both
    /// platforms show the same "check the key in Settings" copy.
    static func mapServerFailure(code: Int?, status: String?, message: String) -> Error {
        let normalizedStatus = status?.uppercased() ?? ""
        if code == 401 || code == 403 || Self.authenticationStatuses.contains(normalizedStatus) {
            return StreamingClientError.invalidAPIKey(
                provider: GeminiTranscribeModels.providerDisplayName
            )
        }
        if code == 429 || Self.rateLimitStatuses.contains(normalizedStatus) {
            return GeminiLiveError.rateLimited(message)
        }
        return GeminiLiveError.server(code: code, status: status, message: message)
    }

    /// Canonical gRPC status strings and the snake_case `code` spellings the
    /// REST error reference documents for the same conditions.
    private static var authenticationStatuses: Set<String> {
        ["UNAUTHENTICATED", "PERMISSION_DENIED", "AUTHENTICATION"]
    }

    private static var rateLimitStatuses: Set<String> {
        ["RESOURCE_EXHAUSTED", "RATE_LIMIT_EXCEEDED", "QUOTA_EXCEEDED", "TOO_MANY_REQUESTS"]
    }

    // MARK: - Private

    private static func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeServerMessage(_ json: String) -> GeminiServerMessage? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeminiServerMessage.self, from: data)
    }
}

// MARK: - Errors

public enum GeminiLiveError: LocalizedError, Equatable {
    case encodingFailed
    case rateLimited(String)
    case server(code: Int?, status: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the Gemini Live transcription request."
        case .rateLimited(let message):
            return "Google Gemini rate limit reached: \(message)"
        case .server(let code, _, let message):
            guard let code else { return "Gemini transcription failed: \(message)" }
            return "Gemini transcription failed (HTTP \(code)): \(message)"
        }
    }
}

// MARK: - Wire models

/// `BidiGenerateContentServerMessage`. Exactly one message-type field is
/// populated per frame, plus the optional error envelope the socket uses to
/// report auth and quota failures.
struct GeminiServerMessage: Decodable {
    let setupComplete: GeminiEmptyPayload?
    let serverContent: GeminiServerContent?
    let goAway: GeminiGoAway?
    let error: GeminiErrorPayload?
}

struct GeminiEmptyPayload: Decodable {}

struct GeminiGoAway: Decodable {
    let timeLeft: String?
}

struct GeminiServerContent: Decodable {
    let inputTranscription: GeminiTranscription?
    let interimInputTranscription: GeminiTranscription?
    let turnComplete: Bool?
    let generationComplete: Bool?
}

struct GeminiTranscription: Decodable {
    let text: String?
}

/// The Gemini API error envelope, shared by the REST and WebSocket surfaces:
/// `{"error": {"code": 429, "message": "...", "status": "RESOURCE_EXHAUSTED"}}`.
/// `code` is an integer over REST and a snake_case string in some Live frames,
/// so both spellings are accepted.
struct GeminiErrorPayload: Decodable {
    let code: Int?
    let status: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case code, status, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try? container.decode(String.self, forKey: .message)
        if let numeric = try? container.decode(Int.self, forKey: .code) {
            self.code = numeric
            self.status = try? container.decode(String.self, forKey: .status)
        } else if let textual = try? container.decode(String.self, forKey: .code) {
            self.code = nil
            self.status = (try? container.decode(String.self, forKey: .status)) ?? textual
        } else {
            self.code = nil
            self.status = try? container.decode(String.self, forKey: .status)
        }
    }
}
