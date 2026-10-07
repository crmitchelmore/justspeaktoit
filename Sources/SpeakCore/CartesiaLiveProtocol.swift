import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Ink-2 automatic-turns stream (`wss://api.cartesia.ai/stt/turns/websocket`):
/// the request that opens it, the one control frame the client sends and the
/// server frames it reads. Pure functions of the protocol, kept beside the
/// client so tests can drive them without a socket.
///
/// Contract (read 2026-09-22):
/// - https://docs.cartesia.ai/api-reference/stt/turns/websocket
/// - https://docs.cartesia.ai/use-the-api/stt/turns
/// - https://docs.cartesia.ai/examples/stt-auto-finalize-websocket
/// - https://github.com/cartesia-ai/cartesia-python `types/stt/stt_auto_finalize_*`
///   (generated from Cartesia's OpenAPI specification)
///
/// Binary PCM goes up as soon as the socket is open: `connected` is
/// informational ("You do not need to wait for this event before sending
/// audio"). `turn.update`/`turn.eager_end` carry the open turn's cumulative
/// text, which the model never revises, and `turn.end` carries the definitive
/// transcript of the completed turn. `request_id` names the connection, not a
/// turn, so turns are delimited only by the order of events. `{"type":"close"}`
/// has every buffered sample processed into events "before the connection
/// closes"; there is no acknowledgement frame, so the server's normal WebSocket
/// closure (1000), reported by the transport through
/// `StreamingWebSocketCloseReporting`, is the end of the stream.
enum CartesiaLiveProtocol {
    static let host = "api.cartesia.ai"
    static let path = "/stt/turns/websocket"
    /// The stream's pinned `Cartesia-Version`, sent by every client that opens
    /// it (the shared client and the macOS controller). Cartesia keeps a pinned
    /// version's contract: "Existing integrations keep running unchanged on
    /// their pinned version" (changelog entry for `2026-08-14`, read
    /// 2026-09-23). The official Python SDK sent `2026-03-01` from 3.1.0 until
    /// 4.0.0, including 3.4.0 (2026-07-21), which added this stream's turn
    /// configuration and keyterms; 4.0.0 moved every request to `2026-08-14`,
    /// whose documented changes concern multilingual voices and
    /// already-deprecated fields. Moving this stream awaits a live receipt of
    /// its handshake and normal closure.
    static let apiVersion = "2026-03-01"
    static let encoding = "pcm_s16le"
    /// The only control frame: end of audio.
    static let closeCommand = #"{"type":"close"}"#

    /// The session is configured entirely by query items. Ink-2 takes no
    /// language hint (its canonical capability is off), so none is sent.
    static func webSocketURL(model: String, sampleRate: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: encoding),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "cartesia_version", value: apiVersion)
        ]
        return components.url
    }

    /// The handshake request. The trimmed key travels only as a bearer token,
    /// never in the query: `Authorization: Bearer` is Cartesia's documented
    /// server authentication (docs.cartesia.ai/use-the-api/api-conventions) and
    /// what both official SDKs send on this handshake. The stream reference
    /// also lists `X-API-Key` and a browser `access_token` query parameter.
    static func webSocketRequest(apiKey: String, model: String, sampleRate: Int) -> URLRequest? {
        guard let url = webSocketURL(model: model, sampleRate: sampleRate) else { return nil }
        var request = URLRequest(url: url)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        return request
    }

    /// A server `error` frame, which ends the session, keeps the provider's
    /// status and message (bounded before it reaches a user-visible message) in
    /// the `Cartesia` error domain.
    static func error(for failure: CartesiaTurnEvent.ServerFailure) -> Error {
        NSError(
            domain: "Cartesia", code: failure.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: boundedMessage(failure.message)]
        )
    }

    /// RFC 6455 normal closure: the only close that ends the stream successfully.
    static let normalClosureCode = 1_000

    /// Whether a receive failure is the peer's normal closure, as the transport
    /// reports it. A failure without a close code, or with any other code, is not.
    static func isNormalClosure(_ error: Error) -> Bool {
        (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode == normalClosureCode
    }

    /// A transport failure. A close frame that did not complete a finish is
    /// reported with its code; otherwise the handshake status only reaches the
    /// transport's description, so a rejected key is recognised from it.
    static func connectionError(_ error: Error) -> Error {
        if let code = (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode {
            return CartesiaStreamingError.closed(code: code)
        }
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Cartesia")
        }
        return error
    }

    static func boundedMessage(_ message: String) -> String {
        let singleLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Cartesia streaming error" }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}

/// One decoded server frame. An unrecognised frame decodes to `nil` and is
/// ignored, so a field or event added upstream cannot end a live recording.
enum CartesiaTurnEvent: Equatable {
    struct ServerFailure: Equatable {
        let statusCode: Int?
        let code: String?
        let message: String
    }

    case connected
    case turnStart
    /// Cumulative text of the open turn.
    case turnUpdate(String)
    /// The model expects the turn to end; `turn.resume` may still follow.
    case turnEagerEnd(String)
    case turnResume
    /// The definitive transcript of the completed turn.
    case turnEnd(String)
    case failure(ServerFailure)

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let transcript = Self.transcript(in: object)
        switch type {
        case "connected": self = .connected
        case "turn.start": self = .turnStart
        // `transcript` is the earlier integration's undocumented event, still
        // read as the open turn's draft, as that parser read it.
        case "turn.update", "transcript": self = .turnUpdate(transcript)
        case "turn.eager_end": self = .turnEagerEnd(transcript)
        case "turn.resume": self = .turnResume
        case "turn.end": self = .turnEnd(transcript)
        case "error": self = .failure(Self.serverFailure(from: object))
        default: return nil
        }
    }

    /// The documented top-level `transcript`. Frames shaped like the earlier
    /// integration's, with the text in `results[].transcript`, are still read
    /// (the first non-empty one), as the shipping macOS parser also reads them.
    private static func transcript(in object: [String: Any]) -> String {
        if let transcript = object["transcript"] as? String { return transcript }
        let results = object["results"] as? [[String: Any]] ?? []
        return results.lazy.compactMap { $0["transcript"] as? String }.first { !$0.isEmpty } ?? ""
    }

    private static func serverFailure(from object: [String: Any]) -> ServerFailure {
        let message = object["message"] as? String ?? object["title"] as? String ?? ""
        return ServerFailure(
            statusCode: object["status_code"] as? Int, code: object["error_code"] as? String, message: message
        )
    }
}

/// Failures specific to the Cartesia stream. Transport and credential failures
/// use the shared ``StreamingClientError``; a server `error` frame keeps the
/// provider's status in the `Cartesia` error domain.
public enum CartesiaStreamingError: LocalizedError, Equatable, Sendable {
    /// The WebSocket did not open within its bound.
    case sessionNotReady
    /// The server closed the socket with this status other than as the normal
    /// end of a finished stream, so the transcript may be incomplete.
    case closed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Cartesia did not open the transcription stream in time."
        case .closed(let code):
            return "Cartesia closed the stream unexpectedly (code \(code)). The recording is available to retry."
        }
    }
}

extension CartesiaLiveClient {
    /// The stream's pinned `Cartesia-Version`; see `CartesiaLiveProtocol.apiVersion`.
    public static let apiVersion = CartesiaLiveProtocol.apiVersion

    /// The one handshake request every client of the stream opens, the macOS
    /// controller included: the documented path and query, the trimmed key as
    /// a bearer token and the pinned version in both the header and the query.
    public static func webSocketRequest(apiKey: String, model: String, sampleRate: Int) -> URLRequest? {
        CartesiaLiveProtocol.webSocketRequest(apiKey: apiKey, model: model, sampleRate: sampleRate)
    }

    /// The stream's URL, documented path and query; also the client's earlier
    /// internal seam, kept source-compatible.
    public static func webSocketURL(model: String, sampleRate: Int) -> URL? {
        CartesiaLiveProtocol.webSocketURL(model: model, sampleRate: sampleRate)
    }

    /// A server `error` frame as the error that ends the session, or `nil` for
    /// any other frame.
    static func providerError(from json: String) -> Error? {
        guard case .failure(let failure)? = CartesiaTurnEvent(data: Data(json.utf8)) else { return nil }
        return CartesiaLiveProtocol.error(for: failure)
    }

    /// The client's earlier internal seam, kept source-compatible.
    static func transcriptEvent(from json: String) -> (text: String, isFinal: Bool)? {
        switch CartesiaTurnEvent(data: Data(json.utf8)) {
        case .turnUpdate(let text)?, .turnEagerEnd(let text)?: return text.isEmpty ? nil : (text, false)
        case .turnEnd(let text)?: return text.isEmpty ? nil : (text, true)
        default: return nil
        }
    }
}
