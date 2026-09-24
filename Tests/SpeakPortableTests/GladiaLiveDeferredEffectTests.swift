import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Effects are decided under the client's lock and performed after it is
/// released, so one can run long after its run was retired, for instance
/// behind a held scheduler. Each re-checks its run immediately before it
/// touches a transport: a retired run never starts a session request or
/// sends a frame.
final class GladiaLiveDeferredEffectTests: XCTestCase {
    func testARunCancelledWhileItsSchedulerIsHeldNeverRequestsASession() async {
        let harness = GladiaHarness()
        let gate = DispatchSemaphore(value: 0)
        let held = expectation(description: "start() is held arming its readiness deadline")
        harness.clock.holdScheduling(GladiaLiveClient.readyDeadline, entered: { held.fulfill() }, until: gate)
        let returned = expectation(description: "start() returned")
        let client = harness.client
        let log = harness.log
        DispatchQueue.global().async {
            client.start(onTranscript: { log.transcript($0, isFinal: $1) }, onError: { log.fail($0) })
            returned.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)
        XCTAssertEqual(client.currentStage, .initiating, "The session request is decided but not yet made")

        client.cancel()
        gate.signal()
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertTrue(harness.sessions.requests.isEmpty, "A retired run never starts its authenticated POST")
        XCTAssertTrue(harness.sockets.sockets.isEmpty)
        XCTAssertTrue(log.errors.isEmpty, "An explicit cancel is not a failure")
    }

    func testARunReplacedWhileItsSchedulerIsHeldLeavesOnlyTheReplacementsRequest() async throws {
        let harness = GladiaHarness()
        let gate = DispatchSemaphore(value: 0)
        let held = expectation(description: "The first start() is held arming its readiness deadline")
        harness.clock.holdScheduling(GladiaLiveClient.readyDeadline, entered: { held.fulfill() }, until: gate)
        let returned = expectation(description: "The first start() returned")
        let client = harness.client
        let retiredLog = GladiaEventLog()
        DispatchQueue.global().async {
            client.start(onTranscript: { retiredLog.transcript($0, isFinal: $1) }, onError: { retiredLog.fail($0) })
            returned.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)

        harness.start()
        XCTAssertEqual(harness.sessions.requests.count, 1, "Only the replacement has asked for a session")
        gate.signal()
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertEqual(harness.sessions.requests.count, 1, "The retired run's deferred request never starts")
        let replacement = try XCTUnwrap(harness.sessions.requests.first)
        XCTAssertEqual(replacement.cancelCount, 0)

        harness.sessions.grant(to: 0)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        socket.open()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0)])
        harness.clock.advance(by: GladiaLiveClient.readyDeadline)
        XCTAssertTrue(retiredLog.errors.isEmpty)
        XCTAssertTrue(harness.log.errors.isEmpty, "The retired run's deadline cannot fail its replacement")
        harness.client.cancel()
    }

    func testAStopRecordingDecidedBeforeACancelIsNeverSent() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Kept.", id: "00-01")
        let gate = DispatchSemaphore(value: 0)
        let held = expectation(description: "The finish is held arming its deadline")
        harness.clock.holdScheduling(GladiaLive.finishBudget, entered: { held.fulfill() }, until: gate)
        let client = harness.client
        let finish = Task { await client.finishAndWait() }
        await fulfillment(of: [held], timeout: 5)
        XCTAssertFalse(socket.stopRecordingSent, "stop_recording is queued behind the held registration")

        client.cancel()
        gate.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertFalse(socket.stopRecordingSent, "A retired run never sends stop_recording")
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0)])
        XCTAssertTrue(harness.log.errors.isEmpty)
    }

    /// `stop_recording` is claimed under the lock but reaches the socket only
    /// when its deferred send runs. An `end_session` that lands in between did
    /// not answer it: Gladia ended the session with the recording unflushed.
    func testEndSessionBeforeTheClaimedStopReachesTheSocketIsNotACompletion() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Kept.", id: "00-01")
        let gate = DispatchSemaphore(value: 0)
        let held = expectation(description: "The finish is held arming its deadline")
        harness.clock.holdScheduling(GladiaLive.finishBudget, entered: { held.fulfill() }, until: gate)
        let client = harness.client
        let log = harness.log
        let finish = Task { () -> String? in
            let transcript = await client.finishAndWait()
            log.note("finish-returned")
            return transcript
        }
        await fulfillment(of: [held], timeout: 5)
        XCTAssertFalse(socket.stopRecordingSent, "stop_recording is claimed, not yet handed to the socket")
        XCTAssertTrue(socket.hasPendingReceive, "The run's receive is already outstanding")

        socket.endSession()
        XCTAssertEqual(log.errors.first as? GladiaStreamingError, .unexpectedSessionEnd,
                       "An end_session that precedes the handoff is not a completion")
        gate.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.", "The confirmed text is kept")
        XCTAssertFalse(socket.stopRecordingSent, "The failed run never hands stop_recording over")
        XCTAssertEqual(log.timeline, ["final:Kept.", "error", "finish-returned"])
    }

    /// Once `stop_recording` has reached the socket, Gladia's `end_session` is
    /// the authoritative answer, even ahead of the send's local completion.
    func testEndSessionAfterTheStopReachesTheSocketCompletesAheadOfItsSendCompletion() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Kept.", id: "00-01")
        let finish = await beginFinish(harness)
        await waitUntil("stop_recording to reach the socket") { socket.stopRecordingSent }
        XCTAssertEqual(socket.heldSendCount, 1, "Its local send completion is still outstanding")

        socket.endSession()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertTrue(harness.log.errors.isEmpty, "end_session after the handoff completes the finish")
        XCTAssertEqual(socket.cancelCount, 1)
    }
}
