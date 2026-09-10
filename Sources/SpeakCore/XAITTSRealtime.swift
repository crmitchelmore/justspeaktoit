import Foundation

/// The `wss://api.x.ai/v1/tts` protocol: URL, client frames and server frames.
///
/// The session is configured entirely by query items — there is no start
/// message — then text is pushed with `text.delta` and closed with
/// `text.done`, and audio comes back as base64 `audio.delta` frames followed by
/// one `audio.done`. `text.clear` is the barge-in: it cancels the utterance
/// being spoken and the service confirms with `audio.clear`.
///
/// Progressive playback uses `pcm`, because headerless little-endian 16-bit
/// samples can be scheduled on an audio node as they arrive; MP3 frames would
/// have to be decoded first.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
/// (read 2026-09-10).
public enum XAITTSRealtime {
    static let host = "api.x.ai"
    static let path = "/v1/tts"

    /// How many characters one `text.delta` frame carries. Well under the
    /// 15,000-character utterance cap, and small enough that the first audio
    /// starts before a long document has finished uploading.
    public static let textChunkCharacters = 400

    /// Groups delta-sized chunks into utterances that each stay inside the
    /// documented per-utterance character maximum.
    ///
    /// One socket speaks one utterance: the deltas are pushed, `text.done`
    /// closes it and the audio comes back. A document longer than the maximum
    /// therefore has to become several utterances, exactly as the REST route
    /// splits it into several requests — sending it as one would have the
    /// service reject text that batch synthesis speaks without complaint.
    public static func utterances(
        from chunks: [String],
        maximumCharacters: Int = XAITTSAPI.maximumTextCharacters
    ) -> [[String]] {
        guard maximumCharacters > 0 else { return [] }
        var utterances: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for chunk in chunks {
            if !current.isEmpty, currentCount + chunk.count > maximumCharacters {
                utterances.append(current)
                current = []
                currentCount = 0
            }
            current.append(chunk)
            currentCount += chunk.count
        }
        if !current.isEmpty { utterances.append(current) }
        return utterances
    }

    public static func webSocketURL(request: XAITTSRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        var items = [
            URLQueryItem(name: "language", value: request.language),
            URLQueryItem(name: "voice", value: request.voiceID),
            URLQueryItem(name: "codec", value: request.codec.rawValue),
            URLQueryItem(name: "sample_rate", value: String(request.sampleRate)),
            URLQueryItem(name: "speed", value: String(request.speed)),
            // Level 1 trades a little quality for a shorter time to first
            // audio, which is the whole point of the streaming route.
            URLQueryItem(name: "optimize_streaming_latency", value: "1")
        ]
        if request.codec == .mp3 {
            items.append(URLQueryItem(name: "bit_rate", value: String(request.bitRate)))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Client frames

    public static func textDeltaJSON(_ delta: String) -> String? {
        json(["type": "text.delta", "delta": delta])
    }

    public static let textDoneJSON = #"{"type":"text.done"}"#
    public static let textClearJSON = #"{"type":"text.clear"}"#

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One frame from `wss://api.x.ai/v1/tts`.
public enum XAITTSRealtimeEvent: Equatable, Sendable {
    /// A chunk of generated audio in the session's codec.
    case audio(Data)
    /// The utterance is complete.
    case done
    /// A `text.clear` was honoured; the queued audio is discarded.
    case cleared
    /// Pronunciation replacements were accepted.
    case sessionUpdated
    case failure(message: String)

    public init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "audio.delta":
            // An undecodable delta is a protocol failure, not silence: playing
            // on would drop a span of speech without telling anyone.
            guard let delta = object["delta"] as? String else { return nil }
            guard let audio = Data(base64Encoded: delta) else {
                self = .failure(message: "xAI sent an audio chunk that is not valid base64")
                return
            }
            self = .audio(audio)
        case "audio.done":
            self = .done
        case "audio.clear":
            self = .cleared
        case "session.updated":
            self = .sessionUpdated
        case "error":
            self = .failure(message: object["message"] as? String ?? "Unknown xAI speech error")
        default:
            return nil
        }
    }

    public init?(frame: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return nil
        }
        self.init(object: object)
    }
}
