import Foundation
import XCTest
@testable import SpeakCore

/// Reuses the shared fake transport, clock and event recorders; only the frames
/// and readiness helper are ElevenLabs-shaped.
final class ElevenLabsFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: ElevenLabsLiveClient

    init(key: String = "synthetic", language: String? = nil) {
        let factory = factory, clock = clock
        client = ElevenLabsLiveClient(
            apiKey: key, language: language,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    func commit(_ text: String, socket: AssemblyAITestSocket? = nil) {
        let socket = socket ?? self.socket
        for _ in 0..<4 {
            client.sendAudio(Data(repeating: 0, count: 160_000))
            socket.completeSend()
        }
        socket.completeSend()
        socket.emit(#"{"message_type":"committed_transcript","text":"\#(text)"}"#)
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// Real handshake, then the server's `session_started` acknowledgement.
    func becomeReady() {
        socket.open()
        socket.emit(#"{"message_type":"session_started"}"#)
    }

    /// Waits until the client has armed a deadline of exactly this length, which
    /// proves an asynchronous wait has registered on the state queue.
    func waitForScheduled(_ seconds: TimeInterval) async {
        for _ in 0..<400 {
            if clock.pending(seconds) > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("No \(seconds)s deadline was scheduled")
    }

    func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }
}

extension ElevenLabsFixture {
    // MARK: - Frame helpers (ElevenLabs realtime shapes)

    static func started() -> String { #"{"message_type":"session_started","session_id":"s"}"# }
    static func partial(_ text: String) -> String {
        #"{"message_type":"partial_transcript","text":"\#(text)"}"#
    }
    static func committed(_ text: String) -> String {
        #"{"message_type":"committed_transcript","text":"\#(text)"}"#
    }
    static func error(_ type: String, _ message: String) -> String {
        #"{"message_type":"\#(type)","error":"\#(message)"}"#
    }

    static func audioChunks(_ socket: AssemblyAITestSocket) -> [Data] {
        socket.objects.compactMap { object in
            guard object["message_type"] as? String == "input_audio_chunk",
                  let base64 = object["audio_base_64"] as? String, !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    static func commitCount(_ socket: AssemblyAITestSocket) -> Int {
        socket.objects.filter { ($0["commit"] as? Bool) == true }.count
    }
}
