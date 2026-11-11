import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MAI's dedicated Realtime API streams before a commit. Voice Live waits for
/// the turn boundary even when configured with the same streaming model.
enum AzureMAIStreamingProtocol {
    static let model = AzureTranscriptionModels.mai2StreamingModel
    static let path = "/mai/v1/realtime"
    static let intervalID = "mai-input"

    static func webSocketRequest(origin: URL, apiKey: String) -> URLRequest? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        if origin.scheme == "https" {
            components.host = components.host?.replacingOccurrences(
                of: ".cognitiveservices.azure.com", with: ".services.ai.azure.com"
            )
        }
        components.scheme = origin.scheme == "http" ? "ws" : "wss"
        components.path = path
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        return request
    }

    static func sessionUpdateJSON(language: String?, sampleRate: Int, eventID: String) throws -> String {
        var transcription: [String: Any] = ["model": model]
        if let value = AzureVoiceLiveProtocol.languageValue(for: language, model: model) {
            transcription["language"] = value
        }
        let event: [String: Any] = [
            "type": "session.update", "event_id": eventID,
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": sampleRate], "transcription": transcription,
                    "turn_detection": NSNull(), "noise_reduction": NSNull()
                ]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw AzureSpeechError.invalidResponse }
        return json
    }
}
