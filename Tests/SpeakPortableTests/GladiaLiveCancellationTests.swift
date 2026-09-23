import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Explicit stop, cancel and restart abort promptly at every phase, wake every
/// waiter, and leave nothing an old run's late callbacks or deadlines can use.
final class GladiaLiveCancellationTests: XCTestCase {
    func testCancelDuringTheSessionRequestAbandonsItAndIgnoresALateReply() {
        let harness = GladiaHarness()
        harness.start()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.client.cancel()
        XCTAssertEqual(harness.sessions.requests.first?.cancelCount, 1)
        harness.sessions.grant()
        harness.clock.advance(by: 60)
        XCTAssertTrue(harness.sockets.sockets.isEmpty, "A late reply never opens a socket")
        XCTAssertTrue(harness.log.errors.isEmpty, "An explicit cancel is not an error")
        XCTAssertEqual(harness.client.admittedAudioBytes, 0, "The run's audio budget is released")
    }

    func testStopBeforeTheHandshakeClosesTheSocketAndIgnoresALateOpen() {
        let harness = GladiaHarness()
        harness.start()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.sessions.grant()
        let socket = harness.socket
        harness.client.stop()
        XCTAssertEqual(socket.cancelCount, 1)
        socket.open()
        socket.endSession()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(harness.log.errors.isEmpty)
    }

    func testStopWhileStreamingAbortsAndIgnoresLateCompletions() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.client.sendAudio(GladiaHarness.pcm(1))
        harness.client.stop()
        XCTAssertEqual(socket.cancelCount, 1)
        socket.completeSend()
        socket.failReceive()
        harness.client.sendAudio(GladiaHarness.pcm(2))
        XCTAssertEqual(socket.sent.count, 1, "Nothing queued is sent after an abort")
        XCTAssertTrue(harness.log.errors.isEmpty)
        XCTAssertEqual(harness.client.currentStage, .closed)
    }

    func testCancellingOneFinishTaskAbortsPromptlyAndWakesEveryWaiter() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Kept on cancel.", id: "00-01")
        let first = await beginFinish(harness)
        let client = harness.client
        let second = Task { await client.finishAndWait() }
        await waitUntil("the second finish to join") { client.finishWaiterCount == 2 }
        first.cancel()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, "Kept on cancel.")
        XCTAssertEqual(secondResult, "Kept on cancel.")
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertTrue(harness.log.errors.isEmpty, "Cancellation is not reported as a failure")
        XCTAssertEqual(harness.clock.count(of: GladiaLive.finishBudget), 1)
    }

    func testAnAlreadyCancelledFinishTaskAbortsWithoutWaiting() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        let client = harness.client
        let finish = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.finishAndWait()
        }
        let result = await finish.value
        XCTAssertNil(result)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertFalse(socket.stopRecordingSent)
        XCTAssertEqual(harness.clock.count(of: GladiaLive.finishBudget), 0)
    }

    func testStopDuringAFinishWakesWaitersWithConfirmedText() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Stopped here.", id: "00-01")
        let finish = await beginFinish(harness)
        socket.partial("Not confirm", id: "00-02")
        harness.client.stop()
        let result = await finish.value
        XCTAssertEqual(result, "Stopped here.")
        XCTAssertTrue(harness.log.errors.isEmpty)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testRestartIsolatesTheOldRunsLateCallbacksAndDeadlines() async {
        let harness = GladiaHarness()
        let oldSocket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.client.sendAudio(GladiaHarness.pcm(1))
        oldSocket.final("Old run.", id: "00-01")
        let oldFinish = await beginFinish(harness)
        // The old run's deadlines now fall due before the replacement's.
        harness.clock.advance(by: 3)

        let replacementLog = GladiaEventLog()
        harness.client.start(
            onTranscript: { replacementLog.transcript($0, isFinal: $1) },
            onError: { replacementLog.fail($0) }
        )
        let oldResult = await oldFinish.value
        XCTAssertEqual(oldResult, "Old run.", "Restart wakes the old finish with its own text")
        XCTAssertEqual(oldSocket.cancelCount, 1)

        harness.client.sendAudio(GladiaHarness.pcm(5))
        oldSocket.completeSend()
        oldSocket.open()
        oldSocket.final("Old late final.", id: "00-02")
        oldSocket.endSession()
        harness.sessions.grant(to: 0)
        harness.clock.advance(by: GladiaLiveClient.readyDeadline - 1)
        XCTAssertTrue(replacementLog.transcripts.isEmpty)
        XCTAssertTrue(replacementLog.errors.isEmpty, "Old deadlines cannot fail the replacement")
        XCTAssertEqual(harness.sockets.sockets.count, 1, "An old reply opens nothing")
        XCTAssertEqual(harness.client.currentStage, .initiating)
        XCTAssertEqual(harness.client.admittedAudioBytes, 3_200, "Only the replacement's audio is held")

        harness.sessions.grant(to: 1)
        let socket = harness.socket
        socket.open()
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(5)])
        socket.final("New run.", id: "00-01")
        XCTAssertEqual(replacementLog.finals, ["New run."])
        harness.client.cancel()
    }

    func testRestartDuringASessionRequestAbandonsItAndIgnoresItsLateReply() throws {
        let harness = GladiaHarness()
        harness.client.sendAudio(GladiaHarness.pcm(9))
        XCTAssertEqual(harness.client.admittedAudioBytes, 0, "Audio before start() has no run to join")
        harness.start()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        harness.start()
        let requests = harness.sessions.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].cancelCount, 1)
        XCTAssertEqual(requests[1].cancelCount, 0)
        XCTAssertEqual(harness.client.admittedAudioBytes, 0, "The replacement starts with its own budget")
        harness.client.sendAudio(GladiaHarness.pcm(1))
        harness.sessions.grant(url: "wss://api.gladia.io/v2/live?token=old-run", to: 0)
        XCTAssertTrue(harness.sockets.sockets.isEmpty, "The abandoned request cannot open a socket")
        harness.sessions.grant(to: 1)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        XCTAssertEqual(socket.request.url?.absoluteString, GladiaHarness.sessionURL)
        socket.open()
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(1)])
        XCTAssertTrue(harness.log.errors.isEmpty)
        harness.client.cancel()
    }

    func testSynchronousTransportsNeverReenterSendOrReceive() async {
        let harness = GladiaHarness()
        harness.sessions.immediateReply = .success((201, Data(GladiaFakeSessions.grantJSON(
            url: GladiaHarness.sessionURL).utf8)))
        harness.sockets.configure = { socket in
            socket.completesSendsSynchronously = true
            for index in 0..<200 { socket.partial("draft \(index)", id: "00-\(index)") }
        }
        let chunks = (0..<GladiaLiveClient.maximumQueuedChunks).map { GladiaHarness.pcm($0, bytes: 64) }
        harness.start()
        let socket = harness.socket
        XCTAssertEqual(harness.log.partials.count, 200, "Queued frames drained by the receive loop, in order")
        XCTAssertEqual(harness.log.partials.last, "draft 199")
        chunks.forEach(harness.client.sendAudio)
        XCTAssertTrue(socket.sent.isEmpty)
        socket.open()
        XCTAssertEqual(socket.sentAudio, chunks, "Every held chunk left from one loop, in order")
        XCTAssertEqual(socket.maximumSendDepth, 1, "A synchronous completion never re-enters send")
        XCTAssertEqual(socket.maximumReceiveDepth, 1, "A synchronous receive never re-enters receive")
        socket.final("Done.", id: "00-final")
        let finish = await beginFinish(harness)
        XCTAssertTrue(socket.stopRecordingSent)
        socket.endSession()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Done.")
        XCTAssertTrue(harness.log.errors.isEmpty)
    }
}
