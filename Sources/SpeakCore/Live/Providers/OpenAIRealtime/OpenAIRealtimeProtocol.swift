import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire contract for OpenAI Realtime transcription sessions, shared by macOS,
/// iOS and Windows. One `?intent=transcription` endpoint, a bearer token and no
/// beta header; the first client event is the GA `session.update` built by
/// `OpenAITranscriptionModels.realtimeSessionUpdatePayload`, and audio is
/// PCM16 mono at the only rate the `audio/pcm` input format accepts.
public enum OpenAIRealtimeProtocol {
    public static let endpoint = "wss://api.openai.com/v1/realtime"
    public static let transcriptionIntent = "transcription"
    public static let transcriptionSessionType = "transcription"

    /// The GA `audio/pcm` input format is 16-bit mono at 24 kHz only.
    public static let sampleRate = 24_000
    public static let bytesPerSample = 2
    public static let bytesPerSecond = sampleRate * bytesPerSample

    /// The server refuses `input_audio_buffer.commit` for buffers shorter than
    /// 100 ms ("buffer too small. Expected at least 100ms of audio"). A shorter
    /// final tail is padded with silence up to this many bytes; an empty
    /// buffer is never committed at all.
    public static let minimumCommitBytes = bytesPerSecond / 10

    /// Authenticated handshake request. The legacy `OpenAI-Beta: realtime=v1`
    /// header pins the pre-GA schema and rejects `session.type`, so it is
    /// deliberately absent.
    public static func webSocketRequest(apiKey: String) -> URLRequest? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "intent", value: transcriptionIntent)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Serialised `session.update` for the shared GA payload. The optional
    /// client `event_id` lets a server `error` be correlated to this exact
    /// event; the session schema itself comes only from the shared helper.
    public static func sessionUpdateJSON(
        model: String, language: String?, prompt: String?, sampleRate: Int, eventID: String? = nil
    ) -> String? {
        var payload = OpenAITranscriptionModels.realtimeSessionUpdatePayload(
            model: model, language: language, prompt: prompt, sampleRate: sampleRate
        )
        if let eventID { payload["event_id"] = eventID }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// `input_audio_buffer.append` for one PCM frame. Base64 never needs JSON
    /// escaping, so the frame is encoded exactly once, at send time.
    public static func appendJSON(pcm16: Data) -> String {
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + pcm16.base64EncodedString() + "\"}"
    }

    /// `input_audio_buffer.commit`, tagged with a client `event_id` so the
    /// server's `error.event_id` names the commit it refers to.
    public static func commitJSON(eventID: String? = nil) -> String {
        guard let eventID, isPlainEventID(eventID) else { return #"{"type":"input_audio_buffer.commit"}"# }
        return "{\"type\":\"input_audio_buffer.commit\",\"event_id\":\"" + eventID + "\"}"
    }

    /// Event identifiers are inlined into JSON, so only unescaped characters are accepted.
    static func isPlainEventID(_ eventID: String) -> Bool {
        !eventID.isEmpty && eventID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// Server events a transcription session can receive, parsed without a socket.
/// GA emits the unprefixed `session.*` names; the pre-GA
/// `transcription_session.*` names remain accepted for compatibility.
public enum OpenAIRealtimeServerEvent: Equatable, Sendable {
    /// First server event on a new connection. Carries the default config, so
    /// it is not readiness.
    case sessionCreated
    /// Acknowledges a `session.update`; readiness for audio.
    case sessionUpdated(sessionType: String?)
    /// The conversation item a commit created; its ID names the completion to wait for.
    case inputAudioBufferCommitted(itemID: String, previousItemID: String?)
    case transcriptionDelta(itemID: String, delta: String)
    case transcriptionCompleted(itemID: String, transcript: String)
    case transcriptionFailed(itemID: String, code: String, message: String)
    /// "Most errors are recoverable and the session will stay open." `eventID`
    /// is the client event that caused the error, when the server names one.
    case error(code: String, message: String, eventID: String?)
    case ignored(type: String)

    /// `nil` for anything that is not a typed JSON object.
    public static func parse(_ text: String) -> OpenAIRealtimeServerEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let itemID = object["item_id"] as? String ?? ""
        switch type {
        case "session.created", "transcription_session.created":
            return .sessionCreated
        case "session.updated", "transcription_session.updated":
            let session = object["session"] as? [String: Any]
            return .sessionUpdated(sessionType: session?["type"] as? String)
        case "input_audio_buffer.committed":
            return .inputAudioBufferCommitted(itemID: itemID, previousItemID: object["previous_item_id"] as? String)
        case "conversation.item.input_audio_transcription.delta":
            let delta = object["delta"] as? String ?? ""
            return delta.isEmpty ? .ignored(type: type) : .transcriptionDelta(itemID: itemID, delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptionCompleted(itemID: itemID, transcript: object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            let details = errorDetails(object["error"], fallbackMessage: nil)
            return .transcriptionFailed(itemID: itemID, code: details.code, message: details.message)
        case "error":
            let details = errorDetails(object["error"], fallbackMessage: object["message"] as? String)
            return .error(code: details.code, message: details.message, eventID: details.eventID)
        default:
            return .ignored(type: type)
        }
    }

    private struct ErrorDetails {
        let code: String
        let message: String
        let eventID: String?
    }

    private static func errorDetails(_ value: Any?, fallbackMessage: String?) -> ErrorDetails {
        let payload = value as? [String: Any]
        let code = payload?["code"] as? String ?? "unknown"
        let message = payload?["message"] as? String ?? fallbackMessage ?? "Unknown OpenAI Realtime error"
        return ErrorDetails(code: code, message: message, eventID: payload?["event_id"] as? String)
    }
}

public enum OpenAIRealtimeStreamingError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidURL
    case encodingFailed
    /// The GA transcription session accepts 24 kHz PCM16 only; nothing is resampled here.
    case invalidSampleRate(Int)
    case invalidPCM
    /// Queued plus in-flight audio exceeded the shared five-second budget.
    /// Reported once; the admitted prefix is still finalised.
    case audioOverflow
    case sessionNotReady
    case unexpectedSessionType(String)
    case serverError(code: String, message: String)
    case transcriptionFailed(itemID: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Please configure it in Settings."
        case .invalidURL:
            return "Failed to construct OpenAI Realtime WebSocket URL"
        case .encodingFailed:
            return "Failed to encode OpenAI Realtime payload"
        case .invalidSampleRate(let rate):
            return "OpenAI Realtime transcription requires 24 kHz PCM16 audio; \(rate) Hz is not supported."
        case .invalidPCM:
            return "OpenAI Realtime requires complete 16-bit PCM samples."
        case .audioOverflow:
            return "OpenAI could not accept audio fast enough. Some audio was not sent; "
                + "the transcript may be incomplete."
        case .sessionNotReady:
            return "OpenAI did not acknowledge the transcription session in time."
        case .unexpectedSessionType(let type):
            return "OpenAI opened a \(type) session instead of a transcription session."
        case .serverError(let code, let message):
            return "OpenAI Realtime error (\(code)): \(message)"
        case .transcriptionFailed(let itemID, let message):
            return "OpenAI could not transcribe item \(itemID): \(message)"
        }
    }
}
