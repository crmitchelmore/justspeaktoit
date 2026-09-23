import Foundation
import XCTest
@testable import SpeakCore

/// Builds the shared client over the reusable fake socket/clock/event doubles.
final class SonioxLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: SonioxLiveClient

    init(key: String = "synthetic", model: String = "stt-rt-v5", language: String? = nil, sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = SonioxLiveClient(
            apiKey: key, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// Real handshake plus the configuration send completing, so audio may flow.
    func becomeReady() {
        socket.open()
        socket.completeSend()
    }

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
