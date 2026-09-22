import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Startup, readiness, ordered PCM and graceful finalisation through the real
/// shared client, with every transport step released by the test.
final class GladiaLiveLifecycleTests: XCTestCase {
    func testAudioHeldBeforeTheHandshakeIsReplayedInCaptureOrderOneSendAtATime() throws {
        let harness = GladiaHarness()
        harness.start()
        let chunks = (0..<5).map { GladiaHarness.pcm($0) }
        chunks[0..<3].forEach(harness.client.sendAudio)
        XCTAssertEqual(harness.client.currentStage, .initiating)
        harness.sessions.grant()
        let socket = harness.socket
        XCTAssertEqual(socket.request.url?.absoluteString, GladiaHarness.sessionURL)
        XCTAssertNil(socket.request.value(forHTTPHeaderField: "x-gladia-key"), "The account key stays off the socket")
        XCTAssertNil(socket.request.value(forHTTPHeaderField: "Authorization"))
        chunks[3...].forEach(harness.client.sendAudio)
        XCTAssertTrue(socket.sent.isEmpty, "Nothing leaves before the real handshake")
        XCTAssertTrue(socket.hasPendingReceive, "Handshake failures surface through the receive")
        XCTAssertEqual(harness.client.admittedAudioBytes, 5 * 3_200)

        socket.emit(GladiaFrames.startSession)
        XCTAssertTrue(socket.sent.isEmpty, "start_session is informational")
        socket.open()
        for index in 0..<5 {
            XCTAssertEqual(socket.sent.count, index + 1, "Exactly one send is in flight")
            XCTAssertEqual(socket.heldSendCount, 1)
            socket.completeSend()
        }
        XCTAssertEqual(socket.sentAudio, chunks, "Bytes and capture order are preserved exactly")
        XCTAssertTrue(socket.sentTexts.isEmpty)
        XCTAssertEqual(harness.client.admittedAudioBytes, 0)
        XCTAssertEqual(harness.client.admittedAudioChunks, 0)
        XCTAssertTrue(harness.log.errors.isEmpty)
        harness.client.cancel()
    }

    func testChunksAreNeverSplitCoalescedOrReencoded() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        let sizes = [3_200, 2, 1_280, 3_200, 640]
        let chunks = sizes.enumerated().map { GladiaHarness.pcm($0.offset, bytes: $0.element) }
        chunks.forEach(harness.client.sendAudio)
        harness.client.sendAudio(Data())
        socket.completeAllSends()
        while socket.sent.count < chunks.count { socket.completeAllSends() }
        XCTAssertEqual(socket.sentAudio, chunks)
        XCTAssertTrue(harness.log.errors.isEmpty)
        harness.client.cancel()
    }

    func testGracefulFinishDrainsAudioThenStopsAndCompletesOnEndSession() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        socket.emit(GladiaFrames.startSession)
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.client.sendAudio(GladiaHarness.pcm(1))
        socket.partial("Hel", id: "00-01")
        socket.final("Hello there.", id: "00-01")

        let finish = await beginFinish(harness)
        harness.client.sendAudio(GladiaHarness.pcm(9))
        XCTAssertFalse(socket.stopRecordingSent, "stop_recording waits for the audio ahead of it")
        socket.completeSend()
        XCTAssertFalse(socket.stopRecordingSent)
        socket.completeSend()
        XCTAssertTrue(socket.stopRecordingSent)
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0), GladiaHarness.pcm(1)],
                       "Audio after a finish is refused")
        XCTAssertEqual(socket.sentTexts, [GladiaLiveProtocol.stopRecordingJSON])
        if case .text? = socket.sent.last {} else { XCTFail("stop_recording must be the last frame") }

        socket.completeSend()
        socket.partial("General", id: "00-02")
        socket.final("General Kenobi.", id: "00-02")
        socket.emit(GladiaFrames.endRecording)
        XCTAssertEqual(socket.cancelCount, 0, "The finish still waits for end_session")
        socket.endSession()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello there. General Kenobi.")
        XCTAssertEqual(harness.log.finals, ["Hello there.", "General Kenobi."], "Late finals are delivered once")
        XCTAssertEqual(harness.log.partials, ["Hel", "General"])
        XCTAssertTrue(harness.log.errors.isEmpty)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertEqual(harness.clock.count(of: GladiaLive.finishBudget), 1)

        socket.final("After the end.", id: "00-03")
        harness.clock.advance(by: 60)
        XCTAssertEqual(harness.log.finals.count, 2, "Nothing after end_session reaches the host")
        XCTAssertTrue(harness.log.errors.isEmpty, "Deadlines of a completed run do nothing")
    }

    func testFinalsFoldOncePerUtteranceIDWithoutTextHeuristics() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.partial("Yes", id: "00-01")
        socket.final("Yes.", id: "00-01")
        socket.final("Yes.", id: "00-01")
        socket.partial("Yes, stale draft", id: "00-01")
        socket.final("Yes.", id: "00-02")
        socket.final("Yes, and more", id: "00-03")
        socket.final("Unidentified.", id: nil)
        socket.final("   ", id: "00-04")
        XCTAssertEqual(harness.log.finals, ["Yes.", "Yes.", "Yes, and more", "Unidentified."])
        XCTAssertEqual(harness.log.partials, ["Yes"], "A partial for a final utterance is not a new draft")

        let finish = await beginFinish(harness)
        socket.completeSend()
        socket.endSession()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Yes. Yes. Yes, and more Unidentified.")
    }

    func testUnicodeTranscriptsArriveIntactFromTextAndBinaryFrames() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        let text = "Café — naïve e\u{301} 👩🏽‍💻 界"
        socket.partial(text, id: "00-01")
        socket.emitBinary(Data(GladiaFrames.transcript(text, id: "00-01", isFinal: true).utf8))
        XCTAssertEqual(harness.log.partials, [text])
        XCTAssertEqual(harness.log.finals, [text])
        harness.client.cancel()
    }

    func testSessionsWithoutAudioOrFinalsFinishEmpty() async {
        let silent = GladiaHarness()
        let socket = silent.startOpen()
        let nothing = await silent.client.finishAndWait()
        XCTAssertNil(nothing)
        XCTAssertTrue(socket.sent.isEmpty, "An empty run has nothing to finalise")
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertTrue(silent.log.errors.isEmpty)

        let early = GladiaHarness()
        early.start()
        let beforeSession = await early.client.finishAndWait()
        XCTAssertNil(beforeSession)
        XCTAssertEqual(early.sessions.requests.first?.cancelCount, 1)
        early.sessions.grant()
        XCTAssertTrue(early.sockets.sockets.isEmpty, "A late session reply opens nothing")

        let draftsOnly = GladiaHarness()
        let draftSocket = draftsOnly.startOpen()
        draftsOnly.client.sendAudio(GladiaHarness.pcm(0))
        draftSocket.completeSend()
        draftSocket.partial("um", id: "00-01")
        let finish = await beginFinish(draftsOnly)
        draftSocket.completeSend()
        draftSocket.endSession()
        let empty = await finish.value
        XCTAssertNil(empty, "Drafts are never promoted to a transcript")
        XCTAssertEqual(draftsOnly.log.partials, ["um"])
        XCTAssertTrue(draftsOnly.log.errors.isEmpty)
    }

    func testConcurrentAndRepeatedFinishesShareOneOutcome() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Shared.", id: "00-01")
        let first = await beginFinish(harness)
        let client = harness.client
        let second = Task { await client.finishAndWait() }
        await waitUntil("the second finish to join") { client.finishWaiterCount == 2 }
        XCTAssertTrue(socket.stopRecordingSent)
        socket.completeSend()
        socket.endSession()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, "Shared.")
        XCTAssertEqual(secondResult, "Shared.")
        let repeated = await client.finishAndWait()
        XCTAssertEqual(repeated, "Shared.", "A finished run keeps answering with its outcome")
        XCTAssertEqual(socket.sentTexts, [GladiaLiveProtocol.stopRecordingJSON], "One stop_recording")
        XCTAssertEqual(harness.clock.count(of: GladiaLive.finishBudget), 1, "One whole deadline")
    }

    func testFinishBeforeTheSessionOpensReplaysHeldAudioThenStops() async {
        let harness = GladiaHarness()
        harness.start()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.client.sendAudio(GladiaHarness.pcm(1))
        let finish = await beginFinish(harness)
        harness.sessions.grant()
        let socket = harness.socket
        XCTAssertTrue(socket.sent.isEmpty)
        socket.open()
        socket.completeAllSends()
        socket.completeAllSends()
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0), GladiaHarness.pcm(1)])
        XCTAssertTrue(socket.stopRecordingSent)
        socket.completeSend()
        socket.final("Quick note.", id: "00-01")
        socket.endSession()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Quick note.")
        XCTAssertTrue(harness.log.errors.isEmpty)
    }

    func testCallbacksMayReenterTheClientWithoutDeadlock() {
        let harness = GladiaHarness()
        let client = harness.client
        let log = harness.log
        client.start(
            onTranscript: { text, isFinal in
                log.transcript(text, isFinal: isFinal)
                if !isFinal { client.sendAudio(GladiaHarness.pcm(7)) }
            },
            onError: { log.fail($0) }
        )
        harness.sessions.grant()
        let socket = harness.socket
        socket.open()
        client.sendAudio(GladiaHarness.pcm(0))
        socket.partial("Reentrant", id: "00-01")
        socket.completeSend()
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0), GladiaHarness.pcm(7)])
        XCTAssertTrue(socket.hasPendingReceive, "The next receive follows the callback")
        client.cancel()
    }
}
