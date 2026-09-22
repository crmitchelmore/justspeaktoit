import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Canonical constants for Gladia's live (Solaria) speech-to-text route.
///
/// Contract, read 2026-09-22:
/// - https://docs.gladia.io/api-reference/v2/live/init — `POST /v2/live` with
///   `x-gladia-key` answers `201` with `{id, created_at, url}`. The `url` "will
///   contain the temporary token to authenticate the session", so the account
///   key is never sent to it.
/// - https://github.com/gladiaio/docs/blob/main/asyncapi.yaml — the socket
///   takes binary PCM and `stop_recording`, and sends `transcript` plus the
///   lifecycle events up to `end_session`, "emitted when the session is closed
///   and no further data will be sent".
/// - https://github.com/gladiaio/sdk (`packages/sdk-js/src/v2/live/session.ts`)
///   — audio flows once the socket opens; `start_session` is informational.
public enum GladiaLive {
    /// Gladia's API origin; `POST /v2/live` is resolved against it.
    public static let baseURL = URL(string: "https://api.gladia.io")!

    /// Gladia's documented default, and only, live model.
    public static let defaultModel = "solaria-1"

    /// The route's final-event window: how long the trailing finals and
    /// `end_session` are given after `stop_recording` leaves. The catalogue's
    /// `postStopFinalizeBudget` for the route reads this value.
    public static let finalEventWindow: TimeInterval = 1.5

    /// Time for a healthy socket to take the at most five seconds of admitted
    /// PCM, and `stop_recording`, once a finish begins.
    public static let drainAllowance: TimeInterval = 1.5

    /// The one whole deadline for `finishAndWait()`, and the client's declared
    /// `finalisationBudget`. It bounds the readiness a finish may inherit, the
    /// drain, `stop_recording` and the `end_session` that answers it, together
    /// from the moment the finish begins. A healthy finish returns as soon as
    /// `end_session` arrives; this is a deadline, never a delay.
    public static let finishBudget: TimeInterval =
        StreamingSessionReadiness.defaultBudget + drainAllowance + finalEventWindow
}

/// Failures the shared Gladia live client reports. None of them carries the
/// session URL, whose query holds the session's temporary token.
public enum GladiaStreamingError: LocalizedError, Equatable {
    /// Gladia accepts 8, 16, 32, 44.1 and 48 kHz PCM only.
    case invalidSampleRate(Int)
    /// PCM16 chunks must contain whole samples.
    case invalidPCM
    /// `POST /v2/live` could not reach Gladia.
    case sessionRequestFailed
    /// Gladia refused to create the session. `message` is Gladia's own
    /// `message` field, bounded; the response body is never echoed.
    case sessionRejected(statusCode: Int, message: String?)
    /// The session response was unreadable or carried no WebSocket URL.
    case invalidSessionResponse
    /// The returned WebSocket URL is not a secure Gladia endpoint, so it was
    /// never contacted.
    case untrustedSessionURL
    /// The session did not open inside its bounded wait.
    case sessionNotReady
    /// The connection failed or closed before the session completed.
    case connectionLost
    /// Gladia reported an error on the socket.
    case server(message: String)
    /// `end_session` arrived before this client sent `stop_recording`.
    case unexpectedSessionEnd
    /// `end_session` did not answer `stop_recording` inside the finish budget.
    case missingCompletion

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Gladia live transcription does not accept \(rate) Hz audio."
        case .invalidPCM:
            return "Gladia live transcription received audio that is not whole 16-bit samples."
        case .sessionRequestFailed:
            return "Could not reach Gladia to start live transcription. Check your connection and try again."
        case .sessionRejected(let statusCode, let message):
            let detail = message.map { ": \($0)" } ?? "."
            return "Gladia refused to start live transcription (HTTP \(statusCode))\(detail)"
        case .invalidSessionResponse:
            return "Gladia returned a live session that could not be read."
        case .untrustedSessionURL:
            return "Gladia returned a live session address that is not a secure Gladia endpoint, so it was not used."
        case .sessionNotReady:
            return "Gladia live transcription did not start in time. Check your connection and try again."
        case .connectionLost:
            return "The connection to Gladia was lost. The words received so far were kept."
        case .server(let message):
            return "Gladia live transcription error: \(message)"
        case .unexpectedSessionEnd:
            return "Gladia ended the session before the recording finished. The words received so far were kept."
        case .missingCompletion:
            return "Gladia did not confirm the end of the transcript in time. The words received so far were kept."
        }
    }
}

/// One decoded server frame the client acts on. Speech events,
/// acknowledgments and anything added upstream decode to `nil`: an
/// unrecognised frame must never end a recording.
enum GladiaLiveEvent: Equatable {
    case transcript(utteranceID: String?, text: String, isFinal: Bool)
    case sessionStarted
    case sessionEnded
    case failure(String)
}

/// Gladia's live wire format: the session request, the session URL's trust
/// boundary and server frames.
enum GladiaLiveProtocol {
    static let initPath = "v2/live"
    static let supportedSampleRates: Set<Int> = [8_000, 16_000, 32_000, 44_100, 48_000]
    static let stopRecordingJSON = #"{"type":"stop_recording"}"#
    /// Server `message` text kept in a rejection, so an error stays readable.
    static let maximumServerMessageLength = 200

    /// Transcripts and lifecycle only. `end_session` needs lifecycle events;
    /// post-processing payloads can be large and would sit between
    /// `stop_recording` and `end_session`, so they, acknowledgments and speech
    /// events stay off. This matches the macOS Gladia transcriber.
    static let messagesConfig: [String: Bool] = [
        "receive_partial_transcripts": true,
        "receive_final_transcripts": true,
        "receive_speech_events": false,
        "receive_pre_processing_events": false,
        "receive_realtime_processing_events": false,
        "receive_post_processing_events": false,
        "receive_acknowledgments": false,
        "receive_errors": true,
        "receive_lifecycle_events": true
    ]

    /// `gladia/solaria-1-streaming` and `solaria-1` both name the live model.
    static func apiModelName(from model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("gladia/") { name = String(name.dropFirst("gladia/".count)) }
        if name.hasSuffix("-streaming") { name = String(name.dropLast("-streaming".count)) }
        return name.isEmpty ? GladiaLive.defaultModel : name
    }

    /// An empty `languages` list is Gladia's documented automatic detection;
    /// one language pins the transcription to it. `en_GB` becomes `en`.
    static func languageConfig(for language: String?) -> [String: Any] {
        let code = TranscriptionLanguageCatalog.providerLanguage(for: language ?? "")?.localeLanguageCode ?? ""
        guard !code.isEmpty else { return ["languages": [String](), "code_switching": true] }
        return ["languages": [code], "code_switching": false]
    }

    static func initBody(model: String, language: String?, sampleRate: Int) -> Data? {
        let payload: [String: Any] = [
            "model": model,
            "encoding": "wav/pcm",
            "bit_depth": 16,
            "sample_rate": sampleRate,
            "channels": 1,
            "language_config": languageConfig(for: language),
            "messages_config": messagesConfig
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func initRequest(endpoint: URL, apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Reads the session's WebSocket URL from a `/v2/live` reply. The API
    /// reference documents `201`; the getting-started guide shows `200`, so any
    /// 2xx is a created session.
    static func sessionURL(statusCode: Int, body: Data, endpoint: URL) -> Result<URL, Error> {
        guard (200..<300).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                return .failure(StreamingClientError.invalidAPIKey(provider: "Gladia"))
            }
            let message = serverMessage(in: body)
            return .failure(GladiaStreamingError.sessionRejected(statusCode: statusCode, message: message))
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["url"] as? String, let url = URL(string: text) else {
            return .failure(GladiaStreamingError.invalidSessionResponse)
        }
        guard isTrustedSessionURL(url, endpoint: endpoint) else {
            return .failure(GladiaStreamingError.untrustedSessionURL)
        }
        return .success(url)
    }

    /// The session URL carries the session's token, so it is honoured only on
    /// the endpoint's own trust boundary: `wss` on the endpoint's host or,
    /// for a Gladia endpoint, another Gladia host. Plain `ws` only mirrors a
    /// plain-HTTP loopback endpoint, the credential-free local test peer.
    static func isTrustedSessionURL(_ url: URL, endpoint: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              let endpointHost = endpoint.host?.lowercased() else { return false }
        switch scheme {
        case "wss":
            return host == endpointHost || (isGladiaHost(host) && isGladiaHost(endpointHost))
        case "ws":
            return endpoint.scheme?.lowercased() == "http" && isLoopback(endpointHost) && host == endpointHost
        default:
            return false
        }
    }

    static func isGladiaHost(_ host: String) -> Bool { host == "gladia.io" || host.hasSuffix(".gladia.io") }

    static func isLoopback(_ host: String) -> Bool { ["127.0.0.1", "::1", "localhost"].contains(host) }

    static func serverMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = object["message"] as? String else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumServerMessageLength))
    }

    static func event(from message: StreamingWebSocketMessage) -> GladiaLiveEvent? {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = object["type"] as? String
        if let failure = failureMessage(in: object, type: type) { return .failure(failure) }
        switch type {
        case "transcript": return transcript(from: object["data"] as? [String: Any])
        case "start_session": return .sessionStarted
        case "end_session": return .sessionEnded
        default: return nil
        }
    }

    /// Add-on and post-processing payloads carry their own `error` for a
    /// failed add-on, which does not affect the transcript. Anything else that
    /// reports an error, or an `error` frame, ends the session.
    private static let addOnTypes: Set<String> = [
        "translation", "named_entity_recognition", "sentiment_analysis",
        "post_transcript", "post_final_transcript", "post_chapterization", "post_summarization"
    ]

    private static func failureMessage(in object: [String: Any], type: String?) -> String? {
        if let type, addOnTypes.contains(type) { return nil }
        let error = object["error"]
        if let text = error as? String, !text.isEmpty { return text }
        if let details = error as? [String: Any] {
            return (details["message"] as? String) ?? (details["exception"] as? String) ?? "Unknown Gladia error"
        }
        guard type == "error" else { return nil }
        return (object["message"] as? String) ?? "Unknown Gladia error"
    }

    private static func transcript(from data: [String: Any]?) -> GladiaLiveEvent? {
        guard let data, let isFinal = data["is_final"] as? Bool,
              let utterance = data["utterance"] as? [String: Any],
              let text = utterance["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .transcript(utteranceID: data["id"] as? String, text: trimmed, isFinal: isFinal)
    }
}

/// The one in-flight `POST /v2/live` a run owns. Cancelling it abandons the
/// request, so a stopped or replaced run never opens its socket.
public protocol GladiaLiveSessionRequest: AnyObject, Sendable {
    func cancel()
}

/// The production session request: one `URLSessionDataTask` that refuses any
/// redirect leaving the endpoint's origin, so `x-gladia-key` stays with Gladia.
final class GladiaURLSessionRequest: GladiaLiveSessionRequest, @unchecked Sendable {
    private let task: URLSessionDataTask

    init(
        session: URLSession, request: URLRequest,
        completion: @escaping @Sendable (Result<(statusCode: Int, body: Data), Error>) -> Void
    ) {
        task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                completion(.success((http.statusCode, data ?? Data())))
            } else {
                completion(.failure(GladiaStreamingError.invalidSessionResponse))
            }
        }
        if let origin = request.url { task.delegate = BatchTranscriptionJob.OriginBoundRedirects(origin: origin) }
    }

    func resume() { task.resume() }

    func cancel() { task.cancel() }
}
