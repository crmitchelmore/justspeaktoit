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
///
/// The session order follows `mistralai/client-python` at commit 80e32d2
/// (`extra/realtime`, read 2026-09-22): read until `session.created` (an
/// `error` first is a handshake failure), send `session.update` before any
/// audio without waiting for `session.updated`, send each chunk as an awaited
/// `input_audio.append`, then `input_audio.flush` and `input_audio.end`, and
/// stop at `transcription.done` or `error`.
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

    /// How long `finishAndWait()` waits for `transcription.done`.
    ///
    /// This is the same number `LiveModelCapabilities` declares as the model's
    /// `postStopFinalizeBudget`, and that entry reads it from here so the two
    /// cannot drift: a client that waited longer than the declared budget
    /// would hold a user's stop open past the bound they were promised.
    /// Missing the frame is not the same as losing the transcript — the deltas
    /// folded during the session are still returned.
    ///
    /// It is one whole deadline, armed when the finish begins: any wait for the
    /// session to become ready, the drain of admitted audio, the flush, the end
    /// and the wait for `transcription.done` all fit inside it.
    public static let finishBudget: TimeInterval = 3
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

/// Lifecycle failures of the live Voxtral stream itself, as opposed to the
/// service's own `error` events (`MistralRealtimeError`). Each is reported
/// rather than absorbed: a finish that did not reach `transcription.done`
/// still returns the text folded so far for recovery, but must not look like a
/// completed transcription.
public enum MistralRealtimeStreamingError: LocalizedError, Equatable {
    /// The socket did not open, or `session.created` did not arrive, in time,
    /// so the session could never be configured and no audio was sent.
    case sessionNotReady
    /// The flush and end left but `transcription.done` never followed, either
    /// because the finish deadline elapsed or because the socket closed first.
    case missingCompletion
    /// `transcription.done` arrived before the flush was sent, so audio the
    /// recording still held was never transcribed.
    case unexpectedCompletion
    /// PCM16 is two bytes per sample; an odd-length chunk would misalign every
    /// sample after it.
    case invalidPCM

    public var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Mistral did not start the realtime transcription session in time."
        case .missingCompletion:
            return "Mistral did not confirm the completed transcription. The recording is available to retry."
        case .unexpectedCompletion:
            return "Mistral ended transcription before all recorded audio was sent. "
                + "The recording is available to retry."
        case .invalidPCM:
            return "Mistral requires complete 16-bit PCM samples."
        }
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

    /// Decodes one complete message from the injected transport. Text and
    /// binary messages both carry JSON; anything that is not a JSON object
    /// decodes to `nil` and is ignored, as the SDK ignores it.
    init?(message: StreamingWebSocketMessage) {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(object: object)
    }
}
