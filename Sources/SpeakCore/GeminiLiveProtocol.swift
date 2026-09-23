import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Gemini Live API wire protocol
//
// Pure request/response shaping for the Gemini Live API's
// `BidiGenerateContent` WebSocket, kept separate from the client so every frame
// and every event shape is testable without a socket.
//
// Contract (read 2026-09-23):
//   https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
//   https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket
//   https://ai.google.dev/api/live
//
// `setup` is the first frame, and "clients should wait for a
// BidiGenerateContentSetupComplete message before sending any additional
// messages". Audio is 16 kHz mono PCM16, base64 inside `realtimeInput.audio`.
// `interimInputTranscription` is the low-latency hypothesis of the utterance in
// flight; `inputTranscription` is the authoritative text of a finished one.
// "The server treats `audio_stream_end` as an immediate turn finalization
// prompt, bypassing the default server-side silence wait time": the end of the
// audio is answered by the final of the utterance in flight, if there is one.
// No frame acknowledges the end of a stream, and the session stays open until
// the client closes it or `goAway` announces the documented ten-minute limit.

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
        GeminiLiveProtocol.webSocketURL(apiKey: apiKey)
    }

    // MARK: - Client messages

    /// The first frame after the socket opens. The selection is pinned to one
    /// of the Live model's documented BCP-47 codes
    /// (`GeminiTranscribeModels.liveLanguageCode(for:)`); `languageCodes: []`
    /// is the documented "detect automatically and allow code-switching"
    /// setting, used for Automatic and for a language the model does not list.
    static func setupMessageJSON(
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String?,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> String? {
        var transcription: [String: Any] = [
            "languageCodes": GeminiTranscribeModels.liveLanguageCode(for: language).map { [$0] } ?? [String](),
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
    /// transport requires. Base64 and the MIME type need no JSON escaping.
    static func audioChunkJSON(_ audio: Data, sampleRate: Int) -> String? {
        GeminiLiveProtocol.audioMessage(audio, sampleRate: sampleRate)
    }

    /// Signals that no more audio is coming, so the server finalises the turn.
    static func audioStreamEndJSON() -> String {
        GeminiLiveProtocol.audioStreamEnd
    }

    // MARK: - Server messages

    /// Decodes a transcription update, or `nil` when the message carries none.
    ///
    /// `interimInputTranscription` is the low-latency hypothesis for the
    /// utterance in flight; `inputTranscription` is the authoritative text for
    /// a finished utterance, which is why the client's `finalShape` is
    /// `.standaloneSegments`.
    static func transcriptEvent(from json: String) -> GeminiLiveTranscriptEvent? {
        guard let content = GeminiLiveProtocol.decodeServerMessage(Data(json.utf8))?.serverContent else {
            return nil
        }
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
        guard let message = GeminiLiveProtocol.decodeServerMessage(Data(json.utf8)) else { return nil }
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
}

// MARK: - Client lifecycle support

/// The socket request, the frames the client sends and the ordered events it
/// reads, for `GeminiLiveClient`'s lifecycle.
enum GeminiLiveProtocol {
    static let provider = GeminiTranscribeModels.providerDisplayName
    static let path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let audioStreamEnd = #"{"realtimeInput":{"audioStreamEnd":true}}"#

    static func webSocketURL(apiKey: String) -> URL? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = GeminiTranscribeModels.apiHost
        components.path = path
        components.queryItems = [URLQueryItem(name: "key", value: trimmed)]
        return components.url
    }

    /// The handshake request: the documented endpoint with the key in its
    /// query, and nothing else.
    static func webSocketRequest(apiKey: String) -> URLRequest? {
        webSocketURL(apiKey: apiKey).map { URLRequest(url: $0) }
    }

    static func audioMessage(_ audio: Data, sampleRate: Int) -> String {
        #"{"realtimeInput":{"audio":{"data":""#
            + audio.base64EncodedString()
            + #"","mimeType":"audio/pcm;rate=\#(sampleRate)"}}}"#
    }

    /// The events one server message carries, in the order the client applies
    /// them: an error envelope alone, else setup completion, the interim, the
    /// final, the turn's completion and `goAway`. An unrecognised or malformed
    /// message carries none, so a field added upstream cannot end a recording.
    static func events(in data: Data) -> [GeminiLiveEvent] {
        guard let message = decodeServerMessage(data) else { return [] }
        if let error = message.error {
            return [.failure(
                code: error.code, status: error.status, message: error.message ?? "Gemini Live transcription failed"
            )]
        }
        var events: [GeminiLiveEvent] = []
        if message.setupComplete != nil { events.append(.setupComplete) }
        if let content = message.serverContent {
            if let interim = trimmed(content.interimInputTranscription?.text), !interim.isEmpty {
                events.append(.interimTranscript(interim))
            }
            // An `inputTranscription` ends its utterance even when it carries no words.
            if let transcription = content.inputTranscription {
                events.append(.finalTranscript(trimmed(transcription.text) ?? ""))
            }
            if content.turnComplete == true { events.append(.turnComplete) }
        }
        if message.goAway != nil { events.append(.goAway) }
        return events
    }

    /// A transport failure. A close frame is reported with its status; without
    /// one, a rejected handshake only reaches the transport's description, so
    /// a rejected key or quota is recognised from it.
    static func connectionError(_ error: Error) -> Error {
        if let code = (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode {
            return GeminiLiveStreamingError.closed(code: code)
        }
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: provider)
        }
        if nsError.code == 429 || description.contains("429") {
            return GeminiLiveError.rateLimited(nsError.localizedDescription)
        }
        return error
    }

    static func decodeServerMessage(_ data: Data) -> GeminiServerMessage? {
        try? JSONDecoder().decode(GeminiServerMessage.self, from: data)
    }

    private static func trimmed(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One server event the client's lifecycle reacts to.
enum GeminiLiveEvent: Equatable {
    case setupComplete
    /// The utterance in flight, restated in full by each interim.
    case interimTranscript(String)
    /// The server finalised an utterance; empty when it had no words.
    case finalTranscript(String)
    case turnComplete
    case goAway
    case failure(code: Int?, status: String?, message: String)
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

/// Failures of the Live session's lifecycle. Server envelopes use
/// ``GeminiLiveError``; transport and credential failures use the shared
/// ``StreamingClientError``.
public enum GeminiLiveStreamingError: LocalizedError, Equatable, Sendable {
    /// The session did not answer its setup in time.
    case sessionNotReady
    /// A frame that is not whole 16-bit samples would misalign every later sample.
    case invalidPCM
    /// The stream ended while the server was still transcribing an utterance
    /// it never finalised, so its words were never confirmed.
    case incompleteUtterance
    /// The server announced the end of the session and it could not be
    /// continued on a new connection.
    case sessionEnded
    /// The server closed the socket with this status before the transcript was complete.
    case closed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Google Gemini did not start the transcription session in time."
        case .invalidPCM:
            return "Google Gemini requires complete 16-bit PCM samples."
        case .incompleteUtterance:
            return "Google Gemini ended before confirming the last words. The recording is available to retry."
        case .sessionEnded:
            return "The Google Gemini session ended and could not be continued. The recording is available to retry."
        case .closed(let code):
            return "Google Gemini closed the stream unexpectedly (code \(code)). The recording is available to retry."
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
