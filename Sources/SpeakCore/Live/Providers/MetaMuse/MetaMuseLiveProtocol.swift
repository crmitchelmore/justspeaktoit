import Foundation

extension MetaMuseLiveClient {
    static func webSocketURL(sessionID: String = UUID().uuidString) -> URL? {
        var components = URLComponents(url: MetaMuseVoiceTranscribe.realtimeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        return components?.url
    }

    static func handshakeData(
        apiKey: String, model: String, sampleRate: Int, language: String?, keywords: [String]
    ) throws -> Data {
        var object: [String: Any] = [
            "authorization": ["accessToken": apiKey],
            "audioEncoding": try Self.audioEncoding(forSampleRate: sampleRate),
            "model": model,
            "mode": MetaMuseMode.endpointing.rawValue,
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false
        ]
        let languageBias = MetaMuseVoiceTranscribe.languageBias(for: language)
        if !languageBias.isEmpty { object["languageBias"] = languageBias }
        if !keywords.isEmpty { object["keywords"] = keywords }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func audioEncoding(forSampleRate sampleRate: Int) throws -> String {
        switch sampleRate {
        case 16_000: return "PCM_16KHZ"
        case 24_000: return "PCM_24KHZ"
        default:
            throw MetaMuseError.invalidAudio(
                "Unsupported capture rate \(sampleRate) Hz; Muse Voice realtime accepts 16 kHz or 24 kHz."
            )
        }
    }

    static func shouldReconnect(didHandshake: Bool, attempt: Int, closeCode: Int?, isEnding: Bool) -> Bool {
        guard !isEnding, !didHandshake, attempt == 0 else { return false }
        guard let closeCode else { return true }
        return closeCode == 1_011
    }

    static func error(fromServerMessage message: String) -> MetaMuseError {
        let lowered = message.lowercased()
        if lowered.contains("auth") || lowered.contains("token") || lowered.contains("credential") {
            return .authentication
        }
        if lowered.contains("rate") || lowered.contains("quota") || lowered.contains("concurrency") {
            return .rateLimited
        }
        if lowered.contains("backlog") || lowered.contains("real-time") || lowered.contains("realtime") {
            return .streamingPolicy(message)
        }
        return .unavailable(message)
    }

    static func error(closeCode: Int, reason: Data?, fallback: Error) -> MetaMuseError {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? fallback.localizedDescription
        switch closeCode {
        case 1_008: return .streamingPolicy(detail)
        case 1_013: return .rateLimited
        case 1_011: return .unavailable(detail)
        default: return .unavailable(detail)
        }
    }
}

enum MetaMuseServerEvent: Equatable {
    case transcript(String)
    case speechComplete(turnID: Int, transcript: String)
    case error(String)
    case lifecycle

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "transcript":
            guard let transcript = object["transcript"] as? String else { return nil }
            self = .transcript(transcript)
        case "speechComplete":
            guard let turnID = object["turnId"] as? Int,
                  let transcript = object["transcript"] as? String else { return nil }
            self = .speechComplete(turnID: turnID, transcript: transcript)
        case "error":
            guard let message = object["message"] as? String else { return nil }
            self = .error(message)
        default: self = .lifecycle
        }
    }
}
