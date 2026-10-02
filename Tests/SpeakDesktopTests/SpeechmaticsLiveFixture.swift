import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Speechmatics client through the injected transport
/// seam. The fake socket, clock and event recorders are the same ones the
/// AssemblyAI, Deepgram and OpenAI lifecycle tests use; only the JSON helpers
/// here are Speechmatics-shaped.
final class SpeechmaticsLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: SpeechmaticsLiveClient

    init(
        key: String = "synthetic", model: String = "enhanced",
        language: String? = nil, sampleRate: Int = 16_000
    ) {
        let factory = factory, clock = clock
        client = SpeechmaticsLiveClient(
            apiKey: key, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: AssemblyAITestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    /// The real handshake, then `StartRecognition` completing, then the
    /// `RecognitionStarted` that releases audio.
    func becomeReady() {
        socket.open()
        socket.completeSend()
        socket.recognitionStarted()
    }

    /// Waits until the client has armed a deadline of exactly this length, which
    /// proves an asynchronous finish has registered on the state queue.
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

extension AssemblyAITestSocket {
    func recognitionStarted() { emit(#"{"message":"RecognitionStarted","id":"sess_1"}"#) }

    func audioAdded(_ seqNo: Int) { emit("{\"message\":\"AudioAdded\",\"seq_no\":\(seqNo)}") }

    func addFinal(_ text: String, start: Double = 0, end: Double = 1) {
        emit("""
        {"message":"AddTranscript","format":"2.1",\
        "metadata":{"transcript":"\(text)","start_time":\(start),"end_time":\(end)},"results":[]}
        """)
    }

    func addTopLevelFinal(_ text: String) {
        emit("{\"message\":\"AddTranscript\",\"transcript\":\"\(text)\",\"results\":[]}")
    }

    func addPartial(_ text: String) {
        emit("""
        {"message":"AddPartialTranscript","format":"2.1",\
        "metadata":{"transcript":"\(text)","start_time":0,"end_time":1},"results":[]}
        """)
    }

    func endOfTranscript() { emit(#"{"message":"EndOfTranscript"}"#) }

    func speechmaticsError(type: String, reason: String) {
        emit("{\"message\":\"Error\",\"type\":\"\(type)\",\"reason\":\"\(reason)\"}")
    }

    /// The last text frame decoded as JSON, in send order.
    var lastControlObject: [String: Any]? { objects.last }

    /// Speechmatics control frames key their kind under `message`, unlike the
    /// OpenAI helpers that read `type`.
    var messageNames: [String] { objects.compactMap { $0["message"] as? String } }
}
