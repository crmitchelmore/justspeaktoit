import Foundation

/// Golden automation frames: the exact bytes a `speak` client writes and the
/// replies an app sends, shared by the Darwin socket, Linux socket and
/// Windows named-pipe client tests so all three transports are held to one
/// wire contract. Bodies are the canonical encoding (sorted keys, no escaped
/// slashes); each frame is a 4-byte big-endian length, then the body.
public enum AutomationWireFixtures {
    public struct Exchange: Sendable {
        public let name: String
        public let request: String
        public let response: String
    }

    /// A status call and the app's reply.
    public static let status = Exchange(
        name: "status",
        request: #"{"command":"status","id":"golden-status","schemaVersion":1,"timeout":5}"#,
        response: #"{"command":"status","id":"golden-status","ok":true,"result":{"sessionActive":true},"#
            + #""schemaVersion":1}"#
    )

    /// A speech call carrying every typed argument kind, and a structured refusal.
    public static let speech = Exchange(
        name: "speech",
        request: #"{"command":"speak_text","id":"golden-say","path":"/srv/out.wav","pitch":-2,"play":true,"#
            + #""provider":"openai","schemaVersion":1,"speed":1.25,"text":"Hello \"there\"","timeout":30,"#
            + #""voice":"alloy"}"#,
        response: #"{"command":"speak_text","error":{"code":"invalid_argument","message":"Unknown voice."},"#
            + #""id":"golden-say","ok":false,"schemaVersion":1}"#
    )

    /// A transcript history call, whose reply carries ISO-8601 dates.
    public static let history = Exchange(
        name: "history",
        request: #"{"command":"get_history","id":"golden-history","limit":2,"schemaVersion":1,"timeout":5}"#,
        response: #"{"command":"get_history","id":"golden-history","ok":true,"result":{"entries":[{"#
            + #""createdAt":"2023-11-14T22:13:20Z","durationSeconds":3,"id":"H1","model":"nova-3","text":"hello","#
            + #""wordCount":1}]},"schemaVersion":1}"#
    )

    public static let exchanges = [status, speech, history]

    /// A reply from a newer app schema, which every client must refuse.
    public static let futureSchemaResponse = #"{"command":"status","id":"golden-status","ok":true,"#
        + #""result":{"sessionActive":true},"schemaVersion":99}"#

    /// `body` behind its 4-byte big-endian length prefix.
    public static func frame(_ body: String) -> Data {
        let payload = Data(body.utf8)
        let length = UInt32(payload.count)
        return Data([
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
        ]) + payload
    }
}
