import Foundation

/// One frame from `wss://api.x.ai/v1/stt`.
///
/// `is_final` and `speech_final` are two separate signals, and the pair decides
/// what a frame means:
///
/// | `is_final` | `speech_final` | meaning |
/// | --- | --- | --- |
/// | `false` | `false` | interim, only with `interim_results=true` |
/// | `true` | `false` | chunk final — roughly 3 s of speech is locked |
/// | `true` | `true` | utterance final — the speaker stopped |
///
/// A locked chunk is never restated, so a chunk final is a standalone segment
/// rather than a restatement of the turn. `transcript.done` arrives once, after
/// the client sends `audio.done`, and carries the authoritative transcript for
/// the whole session.
enum XAISpeechToTextEvent: Equatable {
    case created
    case partial(text: String, isFinal: Bool, speechFinal: Bool, eventID: String?)
    case done(text: String)
    case failure(message: String)

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "transcript.created":
            self = .created
        case "transcript.partial":
            guard let text = object["text"] as? String else { return nil }
            let start = object["start"] as? Double
            let channel = object["channel_index"] as? Int
            self = .partial(
                text: text,
                isFinal: object["is_final"] as? Bool ?? false,
                speechFinal: object["speech_final"] as? Bool ?? false,
                eventID: start.map { "\(channel ?? 0):\($0)" }
            )
        case "transcript.done":
            self = .done(text: object["text"] as? String ?? "")
        case "error":
            self = .failure(message: object["message"] as? String ?? "Unknown xAI streaming error")
        default:
            return nil
        }
    }
}
