import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Soniox real-time WebSocket wire contract, kept beside the client (and out of
// its body) so the endpoint, configuration frame and response parsing can be
// unit-tested without a socket, the way `DeepgramLiveProtocol` does for
// Deepgram. Field names are the ones Soniox documents and the app already
// shipped; nothing here is invented.
//
// Primary references (verified 2026-09-22):
//   https://soniox.com/docs/stt/api-reference/websocket-api
//   https://soniox.com/docs/stt/rt/real-time-transcription
//   https://soniox.com/docs/stt/rt/manual-finalization
//   https://soniox.com/docs/stt/rt/endpoint-detection
extension SonioxLiveClient {
    static let webSocketHost = "stt-rt.soniox.com"
    static let webSocketPath = "/transcribe-websocket"

    /// `wss://stt-rt.soniox.com/transcribe-websocket`. The API key travels in
    /// the first configuration frame, never in the URL, so the request carries
    /// no credential header.
    static func webSocketRequest() -> URLRequest? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = webSocketHost
        components.path = webSocketPath
        guard let url = components.url else { return nil }
        return URLRequest(url: url)
    }

    /// The first client frame. Raw PCM streams need `audio_format`,
    /// `sample_rate` and `num_channels`; `language_hints` is optional and, when
    /// present, carries the ISO-639-1 code the provider expects. The API key is
    /// part of this frame and must never be logged.
    static func configJSON(apiKey: String, model: String, language: String?, sampleRate: Int) -> String? {
        let payload = configPayload(apiKey: apiKey, model: model, language: language, sampleRate: sampleRate)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Broken out from `configJSON` so tests can assert the exact configuration
    /// fields (model, sample rate, language hint) without decoding JSON.
    static func configPayload(apiKey: String, model: String, language: String?, sampleRate: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1
        ]
        if let language {
            payload["language_hints"] = [language.localeLanguageCode]
        }
        return payload
    }

    /// Decodes one Soniox response frame, or `nil` for a payload that is not a
    /// Soniox response object (a keepalive echo, a fragment, or malformed JSON)
    /// so a stray frame never fails a live recording.
    static func parse(_ json: String) -> SonioxLiveFrame? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(SonioxLiveResponse.self, from: data) else {
            return nil
        }
        return SonioxLiveFrame(response)
    }
}

/// One decoded Soniox response, folded into the pieces the client acts on.
///
/// Soniox streams token batches: `is_final` tokens are confirmed and sent
/// exactly once, non-final tokens are provisional and re-sent (revised) on every
/// response until they stabilise. `<fin>` marks a manual finalization completing
/// and `<end>` marks a detected endpoint; both are always final and are signals,
/// not display text. `finished` marks the end-of-stream response, after which
/// the server closes the socket.
struct SonioxLiveFrame: Equatable, Sendable {
    /// Concatenated text of the `is_final` tokens in this frame, excluding the
    /// `<fin>`/`<end>` markers. Tokens carry their own surrounding whitespace.
    var newFinalText = ""
    /// Concatenated text of the non-final tokens in this frame. These replace
    /// the previous frame's non-final tail rather than extending the finals.
    var nonFinalText = ""
    /// A `<fin>` or `<end>` marker was present: the preceding tokens are now
    /// committed.
    var finalized = false
    /// The end-of-stream response; the server closes the socket after it.
    var finished = false
    /// A provider error frame carried an `error_code`.
    var error: (code: Int, message: String)?

    static func == (lhs: SonioxLiveFrame, rhs: SonioxLiveFrame) -> Bool {
        lhs.newFinalText == rhs.newFinalText && lhs.nonFinalText == rhs.nonFinalText
            && lhs.finalized == rhs.finalized && lhs.finished == rhs.finished
            && lhs.error?.code == rhs.error?.code && lhs.error?.message == rhs.error?.message
    }

    init(_ response: SonioxLiveResponse) {
        if let code = response.errorCode {
            let message = response.errorMessage ?? response.errorType ?? "Soniox error \(code)"
            error = (code, message)
        }
        for token in response.tokens ?? [] {
            switch token.text {
            case SonioxLiveFrame.finalizeMarker, SonioxLiveFrame.endpointMarker:
                finalized = true
            default:
                if token.isFinal == true {
                    newFinalText.append(token.text)
                } else {
                    nonFinalText.append(token.text)
                }
            }
        }
        finished = response.finished == true
    }

    /// `{"text":"<fin>","is_final":true}` — a manual `finalize` completed.
    static let finalizeMarker = "<fin>"
    /// `{"text":"<end>","is_final":true}` — a detected endpoint closed a segment.
    static let endpointMarker = "<end>"
}

/// The subset of a Soniox response the live client reads. `tokens` is absent on
/// some control acknowledgements; `finished` only appears on the end-of-stream
/// frame; the `error_*` fields only appear on an error frame.
struct SonioxLiveResponse: Decodable {
    let tokens: [SonioxLiveToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

struct SonioxLiveToken: Decodable {
    let text: String
    let isFinal: Bool?

    private enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}

/// Streaming errors specific to Soniox. Missing/invalid keys, an unbuildable URL
/// and a stalled transport reuse the shared `StreamingClientError` so the app's
/// alerts stay consistent across providers.
public enum SonioxStreamingError: LocalizedError, Equatable {
    case connectionFailed
    case invalidSampleRate(Int)
    case invalidPCM
    case server(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to establish a streaming connection to Soniox."
        case .invalidSampleRate(let rate):
            return "The Soniox audio sample rate (\(rate) Hz) is invalid."
        case .invalidPCM:
            return "Soniox requires complete 16-bit PCM samples."
        case .server(let code, let message):
            return "Soniox reported a streaming error (\(code)): \(message)"
        }
    }
}
