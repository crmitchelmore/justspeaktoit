import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Rev.ai client through the injected transport seam.
/// The fake socket, clock and event recorders are the ones the AssemblyAI,
/// Deepgram, Soniox and xAI lifecycle tests use; only the frame helpers here
/// are shaped like Rev.ai's stream. Every payload is generated: no credential,
/// recording or provider text is used or logged.
final class RevAILiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: RevAILiveClient

    init(token: String = "synthetic-token", language: String? = "en_GB", sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = RevAILiveClient(
            accessToken: token, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// The real handshake followed by `connected`, the frame that permits audio.
    func becomeReady() {
        socket.open()
        socket.connected()
    }

    /// Admits `frames` and completes each send, so all of them are on the wire.
    func stream(_ frames: [Data]) {
        for frame in frames {
            client.sendAudio(frame)
            socket.completeSend()
        }
    }

    /// Waits until `count` finishes are registered on the current run, which
    /// proves an asynchronous finish reached the client rather than sleeping
    /// for a fixed time.
    func waitForFinishWaiters(_ count: Int = 1) async {
        await settle { client.finishWaiterCount >= count }
    }

    func settle(_ predicate: () -> Bool) async { await Self.settle(predicate) }

    /// Polls a condition another thread establishes, failing after two seconds.
    static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }

    /// 100 ms of generated 16 kHz PCM16 mono whose bytes identify the frame.
    static func frame(_ index: Int, count: Int = 3_200) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
    }

    /// The final of the documented example: `punct` elements carry the space
    /// and the stop.
    static let documentedFinal = """
    {"type":"final","ts":1.01,"end_ts":3.2,"elements":[\
    {"type":"text","value":"One","ts":1.04,"end_ts":1.55,"confidence":1.0},\
    {"type":"punct","value":" "},\
    {"type":"text","value":"two","ts":1.84,"end_ts":2.15,"confidence":1.0},\
    {"type":"punct","value":"."}]}
    """
}

/// A peer close as a transport adapter reports it.
struct RevAITestPeerClose: StreamingWebSocketCloseReporting, LocalizedError {
    let webSocketCloseCode: Int?
    var errorDescription: String? { "Synthetic peer close" }
}

extension AssemblyAITestSocket {
    func connected() { emit(#"{"type":"connected","id":"s1d24ax2fd21"}"#) }

    /// A partial hypothesis: word elements only, as Rev.ai sends them.
    func partialHypothesis(_ words: [String]) {
        let elements = words.map { #"{"type":"text","value":"\#($0)"}"# }.joined(separator: ",")
        emit(#"{"type":"partial","ts":0,"end_ts":1,"elements":[\#(elements)]}"#)
    }

    /// A final hypothesis carrying its whole text in one element.
    func finalHypothesis(_ text: String) {
        emit(#"{"type":"final","ts":0,"end_ts":1,"elements":[{"type":"text","value":"\#(text)"}]}"#)
    }

    /// Ends the outstanding receive with the peer's close frame.
    func peerClose(_ code: Int?) { fail(with: RevAITestPeerClose(webSocketCloseCode: code)) }

    /// Text frames that are `EOS`, the protocol's only client text frame.
    var endOfStreamFrames: [String] { controls.filter { $0 == "EOS" } }

    /// Fulfils once the client hands `EOS` to the transport.
    func fulfillOnEndOfStream(_ expectation: XCTestExpectation) {
        onSend = { message in
            if case .text("EOS") = message { expectation.fulfill() }
        }
    }
}
