import Foundation

/// Decodes a WebSocket frame into the JSON object a provider's event type
/// parses. Text and binary frames are both accepted, because several services
/// send their JSON as binary, and a frame that is not a JSON object decodes to
/// `nil` rather than failing a live recording.
enum StreamingFrameDecoding {
    static func jsonObject(from message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension SpeechmaticsRealtimeEvent {
    init?(message: URLSessionWebSocketTask.Message) {
        guard let object = StreamingFrameDecoding.jsonObject(from: message) else { return nil }
        self.init(object: object)
    }
}

extension RevAIStreamingEvent {
    init?(message: URLSessionWebSocketTask.Message) {
        guard let object = StreamingFrameDecoding.jsonObject(from: message) else { return nil }
        self.init(object: object)
    }
}

extension MistralRealtimeEvent {
    init?(message: URLSessionWebSocketTask.Message) {
        guard let object = StreamingFrameDecoding.jsonObject(from: message) else { return nil }
        self.init(object: object)
    }
}
