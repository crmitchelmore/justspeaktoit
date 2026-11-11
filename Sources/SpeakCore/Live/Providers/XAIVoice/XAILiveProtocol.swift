import Foundation

extension XAILiveClient {
    public static func webSocketURL(model: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.x.ai"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url
    }

    public static func sessionUpdateJSON(
        sampleRate: Int,
        language: String?
    ) -> String? {
        var transcription: [String: Any] = [
            "model": XAIVoiceModels.inputTranscriptionAPIName
        ]
        if let languageCode = normalizedLanguageCode(language) {
            transcription["language_hint"] = languageCode
        }
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "reasoning": ["effort": "none"],
                "turn_detection": NSNull(),
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transport": "json",
                        "transcription": transcription
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func transcriptEvent(from json: String) -> (text: String, isFinal: Bool)? {
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(XAITranscriptEvent.self, from: data),
              let transcript = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            return nil
        }
        switch event.type {
        case "conversation.item.input_audio_transcription.updated":
            return (transcript, false)
        case "conversation.item.input_audio_transcription.completed":
            return (transcript, true)
        default:
            return nil
        }
    }

    private static func normalizedLanguageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct XAITranscriptEvent: Decodable {
    let type: String
    let transcript: String?
}
