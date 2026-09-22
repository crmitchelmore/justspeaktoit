import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire contract for Azure Voice Live input transcription, shared by macOS,
/// iOS and Windows: the resource-origin WebSocket request with an `api-key`
/// header, the transcription-only `session.update`, the append and commit
/// frames, and the finalisation barrier. Pure functions only; the lifecycle
/// lives in `AzureVoiceLiveClient`.
///
/// Contract: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-how-to
/// and the Voice Live API reference (read 2026-09-22).
enum AzureVoiceLiveProtocol {
    static let apiVersion = "2026-04-10"
    /// Voice Live needs a chat model even for input transcription. `gpt-4.1` is
    /// non-multimodal, which `azure-speech` and `mai-transcribe` require. No
    /// response is ever requested from it.
    static let chatModel = "gpt-4.1"
    static let path = "/voice-live/realtime"
    /// The only input rate this client declares. Voice Live also accepts
    /// 16 kHz, but the canonical route captures 24 kHz and nothing is resampled.
    static let sampleRate = 24_000
    static let bytesPerSample = 2
    /// 100 ms of 24 kHz PCM16 mono: the frame the hosts send.
    static let frameBytes = sampleRate * bytesPerSample / 10
    /// Returned for a commit that finds the input buffer empty, for example
    /// because server VAD already committed every appended frame.
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

    /// The handshake request for an already validated resource origin. The key
    /// travels only in the `api-key` header, never in the URL.
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

    /// Input transcription only: text modality, no automatic response, and
    /// Azure semantic VAD. `event_id` lets a server `error` name this update.
    static func sessionUpdateJSON(model: String, language: String?, eventID: String?) throws -> String {
        guard transcriptionModels.contains(model) else { throw AzureSpeechError.unsupportedModel }
        var transcription: [String: Any] = ["model": model]
        if let code = languageCode(for: language) { transcription["language"] = code }
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

    /// The Speak selection as Voice Live expects it (`en_GB` → `en-GB`).
    /// Blank, `auto` and Automatic request detection, as for every provider.
    static func languageCode(for selection: String?) -> String? {
        guard let selection, let language = TranscriptionLanguageCatalog.providerLanguage(for: selection) else {
            return nil
        }
        return language.replacingOccurrences(of: "_", with: "-")
    }

    /// One PCM frame. Base64 never needs JSON escaping, so the frame is
    /// encoded exactly once, when it is sent.
    static func appendJSON(pcm16: Data) -> String {
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + pcm16.base64EncodedString() + "\"}"
    }

    /// Commits the audio appended since server VAD last committed. It creates
    /// a user item and starts its transcription; it never creates a response.
    static func commitJSON(eventID: String) -> String {
        "{\"event_id\":\"" + eventID + "\",\"type\":\"input_audio_buffer.commit\"}"
    }

    /// Voice Live rejects changing turn detection once a session has started,
    /// so finalisation cannot switch VAD off. This update restates the
    /// text-only modality instead: the server answers `session.update` events
    /// in order, so its `session.updated` proves every earlier append and
    /// commit was processed and every item they created was announced.
    static func barrierJSON(eventID: String) -> String {
        "{\"event_id\":\"" + eventID + "\",\"session\":{\"modalities\":[\"text\"]},\"type\":\"session.update\"}"
    }

    /// Server error codes are identifiers; anything else is not echoed,
    /// because error envelopes may repeat request details.
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
    /// First event on a new connection; informational, not readiness.
    case sessionCreated
    /// Acknowledges a `session.update`, in the order they were sent.
    case sessionUpdated
    /// A commit, by server VAD or by this client, created this user item.
    case committed(itemID: String)
    case transcriptionDelta(itemID: String, delta: String)
    case transcriptionCompleted(itemID: String, transcript: String)
    /// One item could not be transcribed; the session continues.
    case transcriptionFailed(itemID: String)
    /// `eventID` names the client event that caused it, when Azure reports one.
    case error(code: String, eventID: String?)
    case ignored

    /// `nil` for a frame that is not a typed JSON object. Item events without
    /// an item identity cannot be attributed to a turn and are ignored.
    static func parse(_ data: Data) -> AzureVoiceLiveServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let item = object["item_id"] as? String ?? ""
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "error":
            let details = object["error"] as? [String: Any]
            return .error(code: AzureVoiceLiveProtocol.boundedCode(details?["code"]),
                          eventID: details?["event_id"] as? String)
        default:
            guard !item.isEmpty else { return .ignored }
            return itemEvent(type, item: item, object: object)
        }
    }

    private static func itemEvent(_ type: String, item: String, object: [String: Any]) -> AzureVoiceLiveServerEvent {
        switch type {
        case "input_audio_buffer.committed":
            return .committed(itemID: item)
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

/// Voice Live lifecycle failures. Configuration problems are reported before
/// any connection is attempted; nothing here echoes a key or provider text.
public enum AzureVoiceLiveError: LocalizedError, Equatable, Sendable {
    /// The stored credential is not `key:region` with a valid region.
    case invalidCredentials
    /// Voice Live needs the resource's own HTTPS origin; there is no regional fallback.
    case invalidResourceEndpoint
    /// Only 24 kHz PCM16 is declared to Azure; other rates are refused, not resampled.
    case unsupportedSampleRate(Int)
    /// A frame was not a whole number of 16-bit samples.
    case invalidPCM
    /// Queued plus in-flight audio exceeded its byte or frame bound, so capture
    /// cannot continue without dropping speech.
    case audioOverflow
    /// The socket did not open, or Azure did not acknowledge the configuration, in time.
    case sessionNotReady
    /// Azure rejected the session or a request; only its bounded error code is kept.
    case serverError(code: String)
    /// The finish budget elapsed before every committed turn was transcribed.
    case missingFinalTranscript

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Enter your Azure key and region as key:region."
        case .invalidResourceEndpoint:
            return "Add the HTTPS resource endpoint from Azure in API Keys settings."
        case .unsupportedSampleRate(let rate):
            return "Azure Voice Live transcription needs 24 kHz PCM16 audio; \(rate) Hz is not supported."
        case .invalidPCM:
            return "Azure Voice Live needs complete 16-bit PCM samples."
        case .audioOverflow:
            return "Azure Voice Live could not accept audio fast enough, so live transcription stopped. "
                + "Check your network and start again."
        case .sessionNotReady:
            return "Azure Voice Live did not confirm the transcription session in time. "
                + "Check your network and the resource endpoint."
        case .serverError(let code):
            return "Azure Voice Live rejected the session (\(code)). Check model access and resource region."
        case .missingFinalTranscript:
            return "Azure did not finish the live transcript in time. The text received so far was kept."
        }
    }
}

// Established entry points, kept for existing callers and contract tests.
extension AzureVoiceLiveClient {
    static let finalizationBarrier = #"{"type":"session.update","session":{"modalities":["text"]}}"#

    static func connectionRequest(credentials: String, endpoint: String) throws -> URLRequest {
        let config = try AzureSpeechConfiguration(credentials: credentials)
        let origin = try AzureSpeechConfiguration.resourceURL(endpoint)
        guard let request = AzureVoiceLiveProtocol.webSocketRequest(origin: origin, apiKey: config.apiKey) else {
            throw AzureVoiceLiveError.invalidResourceEndpoint
        }
        return request
    }

    static func sessionUpdate(model: String, language: String?) throws -> String {
        try AzureVoiceLiveProtocol.sessionUpdateJSON(model: model, language: language, eventID: nil)
    }
}
