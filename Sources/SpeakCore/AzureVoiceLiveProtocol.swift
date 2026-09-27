import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire contract for Azure Voice Live input transcription, shared by macOS,
/// iOS and Windows: the resource-origin WebSocket request with an `api-key`
/// header, the transcription-only `session.update`, the append, commit and
/// barrier frames, and the server events the client acts on. Pure functions
/// only; the lifecycle lives in `AzureVoiceLiveClient`.
///
/// Contract, read 2026-09-23: learn.microsoft.com/azure/ai-services/speech-service/
/// voice-live-how-to, voice-live-language-support and the Voice Live API reference.
enum AzureVoiceLiveProtocol {
    static let apiVersion = "2026-04-10"
    /// Voice Live needs a chat model even for input transcription. `azure-speech`
    /// and `mai-transcribe` require a non-multimodal one, and `gpt-4.1` is the
    /// documented pairing. No response is ever requested from it.
    static let chatModel = "gpt-4.1"
    static let path = "/voice-live/realtime"
    /// `input_audio_sampling_rate` accepts only these rates for PCM16 input.
    static let supportedSampleRates: Set<Int> = [16_000, 24_000]
    static let bytesPerSample = 2
    static let speechModel = "azure-speech"
    static let maiModel = "mai-transcribe"
    /// Azure's answer to a commit that finds nothing uncommitted, because
    /// server VAD had already committed every appended frame.
    static let commitEmptyCode = "input_audio_buffer_commit_empty"

    /// The Voice Live transcription models, derived from the canonical live
    /// catalogue so the accepted list cannot drift from the routes.
    static var transcriptionModels: [String] {
        AzureTranscriptionModels.liveOptions.compactMap { LiveTranscriptionRouting.route(for: $0.id)?.apiModelName }
    }

    /// The catalogue identifier whose route sends this transcription model.
    static func catalogID(forModel model: String) -> String? {
        AzureTranscriptionModels.liveOptions.first {
            LiveTranscriptionRouting.route(for: $0.id)?.apiModelName == model
        }?.id
    }

    /// The handshake for an already validated resource origin. The key travels
    /// only in the `api-key` header, never in the URL.
    static func webSocketRequest(origin: URL, apiKey: String) -> URLRequest? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "wss"
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "api-version", value: apiVersion),
            URLQueryItem(name: "model", value: chatModel)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        return request
    }

    /// Input transcription only: text modality, turn detection that never
    /// creates a response, and the declared PCM16 rate. `event_id` lets a
    /// server `error` name this update.
    static func sessionUpdateJSON(
        model: String, language: String?, sampleRate: Int, eventID: String?
    ) throws -> String {
        guard transcriptionModels.contains(model) else { throw AzureSpeechError.unsupportedModel }
        var transcription: [String: Any] = ["model": model]
        if let value = languageValue(for: language, model: model) { transcription["language"] = value }
        let session: [String: Any] = [
            "modalities": ["text"], "input_audio_format": "pcm16", "input_audio_sampling_rate": sampleRate,
            "input_audio_transcription": transcription,
            "turn_detection": ["type": "azure_semantic_vad", "create_response": false, "silence_duration_ms": 500]
        ]
        var event: [String: Any] = ["type": "session.update", "session": session]
        if let eventID { event["event_id"] = eventID }
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw AzureSpeechError.invalidResponse }
        return json
    }

    /// The Speak selection in the form each model documents: `azure-speech`
    /// takes a locale (`en_GB` becomes `en-GB`) and `mai-transcribe` a language
    /// code (`en`). Blank, `auto` and Automatic send nothing, which selects
    /// Azure's multilingual detection.
    static func languageValue(for selection: String?, model: String) -> String? {
        guard let language = TranscriptionLanguageCatalog.providerLanguage(for: selection ?? "") else { return nil }
        let value = model == maiModel ? language.localeLanguageCode : language.replacingOccurrences(of: "_", with: "-")
        return value.isEmpty ? nil : value
    }

    /// One PCM frame. Base64 never needs JSON escaping, so each frame is
    /// encoded once, as it is sent.
    static func appendJSON(pcm16: Data) -> String {
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + pcm16.base64EncodedString() + "\"}"
    }

    /// Commits the audio appended since server VAD last committed. It creates
    /// a user item and starts its transcription; it never creates a response.
    static func commitJSON(eventID: String) -> String {
        "{\"event_id\":\"" + eventID + "\",\"type\":\"input_audio_buffer.commit\"}"
    }

    /// Voice Live refuses to change turn detection once a session has started,
    /// so a finish cannot switch VAD off. This update restates the text-only
    /// modality instead: Azure answers events in order, so its `session.updated`
    /// shows that every earlier append and commit was processed and every item
    /// they created was announced.
    static func barrierJSON(eventID: String) -> String {
        "{\"event_id\":\"" + eventID + "\",\"session\":{\"modalities\":[\"text\"]},\"type\":\"session.update\"}"
    }

    /// Server error codes are identifiers. Anything else is replaced, because
    /// an error envelope can repeat request details.
    static func boundedCode(_ value: Any?) -> String {
        guard let code = value as? String, !code.isEmpty, code.count <= 64,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }) else {
            return "unknown"
        }
        return code
    }
}

/// Server events a transcription session acts on, parsed without a socket.
enum AzureVoiceLiveServerEvent: Equatable, Sendable {
    /// The first event on a connection. Informational, never readiness.
    case sessionCreated
    /// Answers one `session.update`; Azure answers them in the order sent.
    case sessionUpdated
    /// A commit, by server VAD or by this client, created this user item.
    case committed(itemID: String?)
    case transcriptionDelta(itemID: String, delta: String)
    case transcriptionCompleted(itemID: String, transcript: String)
    /// One item could not be transcribed; the session continues.
    case transcriptionFailed(itemID: String)
    /// `eventID` names the client event behind the error when Azure reports one.
    case error(code: String, eventID: String?)
    case ignored

    /// `nil` for a frame that is not a typed JSON object. Transcription events
    /// without an item cannot be attributed to a turn and are ignored.
    static func parse(_ data: Data) -> AzureVoiceLiveServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let item = (object["item_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.committed": return .committed(itemID: item)
        case "error":
            let details = object["error"] as? [String: Any]
            return .error(code: AzureVoiceLiveProtocol.boundedCode(details?["code"]),
                          eventID: details?["event_id"] as? String)
        default:
            guard let item else { return .ignored }
            return transcriptionEvent(type, item: item, object: object)
        }
    }

    private static func transcriptionEvent(
        _ type: String, item: String, object: [String: Any]
    ) -> AzureVoiceLiveServerEvent {
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let delta = object["delta"] as? String ?? ""
            return delta.isEmpty ? .ignored : .transcriptionDelta(itemID: item, delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptionCompleted(itemID: item, transcript: object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            return .transcriptionFailed(itemID: item)
        default:
            return .ignored
        }
    }
}

/// Voice Live session failures that `AzureSpeechError` does not already name.
/// Nothing here echoes a key, a request or provider text.
public enum AzureVoiceLiveError: LocalizedError, Equatable, Sendable {
    /// Only 16 or 24 kHz PCM16 can be declared to Azure; nothing is resampled.
    case unsupportedSampleRate(Int)
    /// A frame was not a whole number of 16-bit samples.
    case invalidPCM
    /// The socket did not open, or Azure did not confirm the configuration, in time.
    case sessionNotReady
    /// Azure refused the transcription session; only its bounded code is kept.
    case sessionRejected(code: String)
    /// Azure reported an error during the session, including one that answers
    /// the commit or the finalisation barrier. It is never a completion.
    case serverError(code: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let rate):
            return "Azure Voice Live transcription needs 16 or 24 kHz PCM16 audio; \(rate) Hz is not supported."
        case .invalidPCM:
            return "Azure Voice Live needs complete 16-bit PCM samples."
        case .sessionNotReady:
            return "Azure Voice Live did not confirm the transcription session in time. "
                + "Check your network and the resource endpoint."
        case .sessionRejected(let code):
            return "Azure Voice Live rejected the session (\(code)). Check model access and resource region."
        case .serverError(let code):
            return "Azure Voice Live reported an error (\(code)) and stopped transcribing."
        }
    }
}

// Established entry points, kept for existing callers and contract tests.
extension AzureVoiceLiveClient {
    static let finalizationBarrier = #"{"type":"session.update","session":{"modalities":["text"]}}"#

    static func connectionRequest(credentials: String, endpoint: String) throws -> URLRequest {
        let configuration = try AzureSpeechConfiguration(credentials: credentials)
        let origin = try AzureSpeechConfiguration.resourceURL(endpoint)
        guard let request = AzureVoiceLiveProtocol.webSocketRequest(origin: origin, apiKey: configuration.apiKey) else {
            throw StreamingClientError.invalidURL
        }
        return request
    }

    static func sessionUpdate(model: String, language: String?) throws -> String {
        try AzureVoiceLiveProtocol.sessionUpdateJSON(model: model, language: language, sampleRate: 24_000, eventID: nil)
    }
}
