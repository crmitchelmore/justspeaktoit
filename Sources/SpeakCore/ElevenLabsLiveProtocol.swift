import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ElevenLabs Scribe v2 realtime wire protocol: which endpoint a session speaks,
// how a PCM frame is framed and how the events that come back are read. Kept
// beside the client (and out of its body) so the URL and parsing rules can be
// unit-tested without a socket, the way `DeepgramLiveProtocol` is.
//
// Verified against ElevenLabs' realtime speech-to-text reference and the
// shipping Apple `ElevenLabsLiveTranscriber`: a `/v1/speech-to-text/realtime`
// socket, `xi-api-key` auth, base64 `input_audio_chunk` frames and
// `partial_transcript` / `committed_transcript` results under
// `commit_strategy=manual`. No field here is invented; unknown frames are ignored.
public enum ElevenLabsLiveProtocol {
    public static let host = "api.elevenlabs.io"
    public static let path = "/v1/speech-to-text/realtime"
    static let supportedSampleRates: Set<Int> = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

    /// Builds the streaming URL for `modelID`. `audio_format` encodes the
    /// stream's PCM rate (`pcm_16000`); `commit_strategy=manual` uses client-owned
    /// bounded segmentation, and an optional ISO-639 `language_code` is added
    /// only when the caller pins a language.
    public static func webSocketURL(modelID: String, language: String?, sampleRate: Int) -> URL? {
        guard supportedSampleRates.contains(sampleRate) else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "manual")
        ]
        if let language = TranscriptionLanguageCatalog.providerLanguage(for: language ?? "") {
            items.append(URLQueryItem(name: "language_code", value: language.localeLanguageCode))
        }
        components.queryItems = items
        return components.url
    }

    /// One PCM frame as an `input_audio_chunk`. Base64 never needs JSON
    /// escaping, so the frame is encoded exactly once, at send time.
    public static func audioChunkJSON(pcm16: Data, sampleRate: Int) -> String {
        "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\""
            + pcm16.base64EncodedString()
            + "\",\"sample_rate\":\(sampleRate)}"
    }

    /// A manual commit: an empty chunk carrying `commit:true`, which flushes any
    /// audio in the current manually owned segment so the trailing words come back
    /// as a `committed_transcript` before the socket closes.
    public static func commitJSON() -> String {
        #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true}"#
    }
}

/// A decoded server frame. `parse` returns `nil` for anything that is not a
/// typed JSON object, so a malformed frame is ignored rather than failing a
/// live recording.
public enum ElevenLabsRealtimeEvent: Equatable, Sendable {
    /// The session is ready; audio may now be sent.
    case sessionStarted
    /// An interim result for the current, not-yet-committed segment.
    case partialTranscript(String)
    /// A finalised segment. ElevenLabs segments are standalone and concatenated.
    case committedTranscript(String)
    /// The key was rejected or lacks speech-to-text (Scribe) access.
    case authError(String)
    /// A non-authentication server error that ends the session.
    case serverError(type: String, message: String)
    /// A non-fatal notice the session survives.
    case warning(String)
    /// A recognised but non-actionable frame.
    case ignored(type: String)

    /// Error `message_type`s that end the session, per the realtime reference.
    /// `auth_error` and `warning` are handled separately (invalid key vs. survivable).
    static let terminalErrorTypes: Set<String> = [
        "error", "quota_exceeded", "rate_limited", "commit_throttled", "input_error",
        "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity",
        "transcriber_error", "session_time_limit_exceeded", "resource_exhausted",
        "queue_overflow", "unaccepted_terms"
    ]

    public static func parse(_ text: String) -> ElevenLabsRealtimeEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = object["message_type"] as? String else { return nil }
        let text = object["text"] as? String ?? ""
        switch messageType {
        case "session_started":
            return .sessionStarted
        case "partial_transcript":
            return .partialTranscript(text)
        case "committed_transcript":
            return .committedTranscript(text)
        case "committed_transcript_with_timestamps":
            // Additional metadata for an already delivered segment. Text-only
            // consumers must not append it as another utterance.
            return .ignored(type: messageType)
        case "auth_error":
            return .authError(object["error"] as? String ?? messageType)
        case "warning":
            return .warning(object["warning"] as? String ?? object["error"] as? String ?? messageType)
        case let type where terminalErrorTypes.contains(type):
            return .serverError(type: type, message: object["error"] as? String ?? type)
        default:
            return .ignored(type: messageType)
        }
    }
}

/// Streaming-specific ElevenLabs errors, kept distinct from the legacy
/// ``ElevenLabsLiveError`` so the established connection-error surface stays
/// unchanged. Mirrors `AssemblyAIStreamingError` / `OpenAIRealtimeStreamingError`.
public enum ElevenLabsStreamingError: LocalizedError, Equatable, Sendable {
    case sessionNotReady
    case serverError(type: String, message: String)
    case invalidSampleRate(Int)
    case invalidPCM
    case missingCompletion
    case unexpectedCompletion

    public var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "ElevenLabs did not start the transcription session in time."
        case .serverError(let type, let message):
            return "ElevenLabs reported a streaming error (\(type)): \(message)"
        case .invalidSampleRate(let rate):
            return "ElevenLabs does not support the configured PCM sample rate (\(rate) Hz)."
        case .invalidPCM:
            return "ElevenLabs requires complete 16-bit PCM samples."
        case .unexpectedCompletion:
            return "ElevenLabs returned an unrequested transcription segment. The recording is available to retry."
        case .missingCompletion:
            return "ElevenLabs did not confirm the completed transcription. The recording is available to retry."
        }
    }
}
