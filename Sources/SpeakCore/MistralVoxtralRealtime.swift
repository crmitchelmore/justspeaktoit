import Foundation

/// Canonical identifiers and limits for Mistral's Voxtral Realtime
/// transcription WebSocket.
///
/// Contract: https://docs.mistral.ai/studio/audio/speech_to_text/realtime_transcription
/// and https://docs.mistral.ai/studio-api/audio/speech_to_text/realtime_transcription/client_auth
/// (read 2026-09-10).
///
/// The endpoint URL and both authentication transports are documented on that
/// second page. The message and event shapes below are **not** in Mistral's
/// prose documentation or in its public OpenAPI description; they come from
/// Mistral's own published SDKs (`mistralai` on PyPI, `@mistralai/mistralai` on
/// npm), which are official vendor code rather than official vendor reference.
/// Every event model there is open to unknown fields, so this client parses
/// leniently and ignores anything it does not recognise.
public enum MistralVoxtralRealtime {
    /// Streaming catalogue identifier. The dated model id is pinned rather than
    /// the `-latest` alias so a future realtime model cannot silently change
    /// the protocol underneath a saved selection.
    public static let liveCatalogID = "mistral/voxtral-mini-transcribe-realtime-2602-streaming"
    /// The model id the socket's `model` query parameter carries.
    public static let apiModelID = "voxtral-mini-transcribe-realtime-2602"

    static let webSocketHost = "api.mistral.ai"
    static let webSocketPath = "/v1/audio/transcriptions/realtime"

    /// The only encoding the app captures, and the one every Mistral example
    /// uses. The documented enum also names `pcm_s32le`, `pcm_f16le`,
    /// `pcm_f32le`, `pcm_mulaw` and `pcm_alaw`.
    static let encoding = "pcm_s16le"

    /// Milliseconds of context Voxtral gathers before it starts transcribing.
    /// Mistral's own microphone example uses 480 ms, which its announcement
    /// puts within 1-2% word error rate of the offline model. The allowed
    /// range and default are not documented.
    static let targetStreamingDelayMilliseconds = 480

    /// Hard cap on the *decoded* byte length of one `input_audio.append`
    /// payload: 256 KiB, or eight seconds of 16 kHz mono PCM16. Audio is
    /// chunked before base64 encoding, never after.
    static let maximumAppendBytes = 262_144

    /// How long `finishAndWait()` waits for `transcription.done`. Voxtral
    /// Realtime emits no per-utterance final, so this frame is the only
    /// authoritative transcript and the budget is correspondingly generous.
    static let finishBudget: TimeInterval = 6
}

/// Failures the shared Mistral realtime transport reports.
public enum MistralRealtimeError: LocalizedError, Equatable {
    /// The service's `error` event. `code` is Mistral's own internal error
    /// number — neither an HTTP status nor a WebSocket close code.
    case server(message: String, code: Int?)
    /// An `error` event that arrived before `session.created`, which the SDK
    /// treats as a fatal handshake failure.
    case handshakeRejected(message: String)

    public var errorDescription: String? {
        switch self {
        case .server(let message, let code):
            guard let code else { return "Mistral realtime error: \(message)" }
            return "Mistral realtime error \(code): \(message)"
        case .handshakeRejected(let message):
            return "Mistral rejected the realtime session: \(message)"
        }
    }

    /// Reads the `error` object. `message` is a string on most routes and an
    /// object carrying `detail` on others, so it is read untyped rather than
    /// through one `Decodable` the other shape would fail.
    static func message(from error: [String: Any]) -> String {
        if let text = error["message"] as? String, !text.isEmpty { return text }
        if let object = error["message"] as? [String: Any],
           let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return "Unknown Mistral realtime error"
    }
}

/// One decoded Voxtral Realtime server event.
///
/// Mistral's own event models are open to unknown fields and new event types,
/// so anything this app does not act on — `session.updated`,
/// `transcription.language`, `transcription.segment`, or a type added upstream —
/// decodes to `nil` and is ignored rather than treated as a failure.
enum MistralRealtimeEvent {
    case sessionCreated
    case delta(String)
    case done(text: String)
    case failure(message: String, code: Int?)

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "session.created":
            self = .sessionCreated
        case "transcription.text.delta":
            guard let fragment = object["text"] as? String, !fragment.isEmpty else { return nil }
            self = .delta(fragment)
        case "transcription.done":
            self = .done(text: (object["text"] as? String) ?? "")
        case "error":
            let payload = (object["error"] as? [String: Any]) ?? [:]
            self = .failure(
                message: MistralRealtimeError.message(from: payload),
                code: payload["code"] as? Int
            )
        default:
            return nil
        }
    }
}
