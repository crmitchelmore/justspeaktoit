import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared xAI speech-to-text client through the injected
/// transport seam. The fake socket, clock and event recorders are the ones the
/// AssemblyAI, Deepgram and OpenAI lifecycle tests use; only the frame helpers
/// here are shaped like `wss://api.x.ai/v1/stt`. Every payload is generated:
/// no credential, recording or provider text is used or logged.
final class XAISpeechToTextLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: XAISpeechToTextLiveClient

    init(key: String = "synthetic", language: String? = nil, keywords: [String] = [], sampleRate: Int = 24_000) {
        let factory = factory, clock = clock
        client = XAISpeechToTextLiveClient(
            apiKey: key, language: language, keywords: keywords, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// The real handshake followed by the frame that permits audio.
    func becomeReady() {
        socket.open()
        socket.transcriptCreated()
    }

    /// Waits until the client has armed `count` deadlines of exactly this
    /// length, which proves an asynchronous wait has registered on the state
    /// queue rather than sleeping for a fixed time.
    func waitForScheduled(_ seconds: TimeInterval, count: Int = 1) async {
        for _ in 0..<400 {
            if clock.pending(seconds) >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fewer than \(count) \(seconds)s deadlines were scheduled")
    }

    /// 100 ms of generated 24 kHz PCM16 mono with a recognisable fill byte.
    static func frame(_ fill: UInt8, count: Int = 4_800) -> Data { Data(repeating: fill, count: count) }
}

extension AssemblyAITestSocket {
    static let audioDoneFrame = #"{"type":"audio.done"}"#

    /// Text frames that are `audio.done`, the protocol's only control frame.
    var audioDoneFrames: [String] { controls.filter { $0 == Self.audioDoneFrame } }

    /// Fulfils once the client hands `audio.done` to the transport.
    func fulfillOnAudioDone(_ expectation: XCTestExpectation) {
        onSend = { message in
            if case .text(let text) = message, text == Self.audioDoneFrame { expectation.fulfill() }
        }
    }

    func transcriptCreated() { emit(#"{"type":"transcript.created"}"#) }

    func transcriptPartial(
        _ text: String, isFinal: Bool, speechFinal: Bool? = nil, start: Double? = nil, channel: Int? = nil
    ) {
        var object: [String: Any] = [
            "type": "transcript.partial", "text": text, "is_final": isFinal, "speech_final": speechFinal ?? isFinal
        ]
        if let start { object["start"] = start }
        if let channel { object["channel_index"] = channel }
        emitXAI(object)
    }

    func transcriptDone(_ text: String) { emitXAI(["type": "transcript.done", "text": text, "duration": 1.5]) }

    func xaiError(_ message: String) { emitXAI(["type": "error", "message": message]) }

    private func emitXAI(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("Invalid synthetic provider event")
        }
        emit(text)
    }
}
