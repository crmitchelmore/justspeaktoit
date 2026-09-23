import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Every terminal failure is published once, retires the run first, keeps the
/// confirmed text and never exposes the session token.
final class GladiaLiveFailureTests: XCTestCase {
    func testMissingKeyUnsupportedRateAndPartialSamplesFailWithoutARequest() {
        let unkeyed = GladiaHarness(apiKey: "  ")
        unkeyed.start()
        XCTAssertEqual(unkeyed.log.errors.first?.localizedDescription,
                       StreamingClientError.missingAPIKey(provider: "Gladia").localizedDescription)
        XCTAssertTrue(unkeyed.sessions.requests.isEmpty)

        let oddRate = GladiaHarness(sampleRate: 22_050)
        oddRate.start()
        XCTAssertEqual(oddRate.log.errors.first as? GladiaStreamingError, .invalidSampleRate(22_050))
        XCTAssertTrue(oddRate.sessions.requests.isEmpty)

        let harness = GladiaHarness()
        let socket = harness.startOpen()
        harness.client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(harness.log.errors.first as? GladiaStreamingError, .invalidPCM)
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testSessionRequestFailuresSurfaceTypedErrorsAndOpenNothing() {
        let failingURL = "https://api.gladia.io/v2/live?token=secret-token"
        let cases: KeyValuePairs<String, ((GladiaFakeSessions) -> Void, Error)> = [
            "401": ({ $0.reply(status: 401, json: #"{"message":"Unauthorized"}"#) },
                    StreamingClientError.invalidAPIKey(provider: "Gladia")),
            "422": ({ $0.reply(status: 422, json: #"{"message":"Invalid sample rate"}"#) },
                    GladiaStreamingError.sessionRejected(statusCode: 422, message: "Invalid sample rate")),
            "transport": ({ $0.fail(URLError(.notConnectedToInternet, userInfo: [
                NSURLErrorFailingURLStringErrorKey: failingURL
            ])) }, GladiaStreamingError.sessionRequestFailed),
            "malformed": ({ $0.reply(status: 201, json: #"{"id":"x"}"#) }, GladiaStreamingError.invalidSessionResponse),
            "plaintext": ({ $0.grant(url: "ws://api.gladia.io/v2/live?token=secret-token") },
                          GladiaStreamingError.untrustedSessionURL),
            "off-domain": ({ $0.grant(url: "wss://collector.example/v2/live?token=secret-token") },
                           GladiaStreamingError.untrustedSessionURL)
        ]
        for (name, (reply, expected)) in cases {
            let harness = GladiaHarness()
            harness.start()
            harness.client.sendAudio(GladiaHarness.pcm(0))
            reply(harness.sessions)
            XCTAssertEqual(harness.log.errors.map(\.localizedDescription), [expected.localizedDescription], name)
            XCTAssertTrue(harness.sockets.sockets.isEmpty, "\(name): no socket may open")
            let reported = harness.log.errors.map { String(describing: $0) + $0.localizedDescription }
            XCTAssertFalse(reported.joined().contains("secret-token"), "\(name) leaked the session token")
            XCTAssertEqual(harness.client.currentStage, .closed)
        }
    }

    func testReadinessDeadlineFailsASessionThatNeverOpens() {
        let waitingForReply = GladiaHarness()
        waitingForReply.start()
        waitingForReply.clock.advance(by: GladiaLiveClient.readyDeadline - 0.5)
        XCTAssertTrue(waitingForReply.log.errors.isEmpty)
        waitingForReply.clock.advance(by: 0.5)
        XCTAssertEqual(waitingForReply.log.errors.first as? GladiaStreamingError, .sessionNotReady)
        XCTAssertEqual(waitingForReply.sessions.requests.first?.cancelCount, 1)

        let waitingForHandshake = GladiaHarness()
        waitingForHandshake.start()
        waitingForHandshake.sessions.grant()
        waitingForHandshake.clock.advance(by: GladiaLiveClient.readyDeadline)
        XCTAssertEqual(waitingForHandshake.log.errors.first as? GladiaStreamingError, .sessionNotReady)
        XCTAssertEqual(waitingForHandshake.socket.cancelCount, 1)
        waitingForHandshake.socket.open()
        XCTAssertTrue(waitingForHandshake.socket.sent.isEmpty, "A late handshake releases nothing")
    }

    func testFinishDeadlineNamesTheStageThatStalledAndKeepsConfirmedText() async {
        let unopened = GladiaHarness()
        unopened.start()
        unopened.client.sendAudio(GladiaHarness.pcm(0))
        let neverReady = await beginFinish(unopened)
        unopened.clock.advance(by: GladiaLive.finishBudget)
        let unopenedResult = await neverReady.value
        XCTAssertNil(unopenedResult)
        XCTAssertEqual(unopened.log.errors.first as? GladiaStreamingError, .sessionNotReady)

        let stalled = GladiaHarness()
        let stalledSocket = stalled.startOpen()
        stalled.client.sendAudio(GladiaHarness.pcm(0))
        stalledSocket.final("Kept.", id: "00-01")
        let draining = await beginFinish(stalled)
        stalled.clock.advance(by: GladiaLive.finishBudget)
        let stalledResult = await draining.value
        XCTAssertEqual(stalledResult, "Kept.")
        XCTAssertEqual(stalled.log.errors.first?.localizedDescription,
                       StreamingClientError.transportStalled(provider: "Gladia").localizedDescription)
        XCTAssertFalse(stalledSocket.stopRecordingSent)

        let unanswered = GladiaHarness()
        let socket = unanswered.startOpen()
        unanswered.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("Confirmed.", id: "00-01")
        let waiting = await beginFinish(unanswered)
        await waitUntil("stop_recording to reach the socket") { socket.stopRecordingSent }
        socket.completeSend()
        socket.partial("Unconfirmed dra", id: "00-02")
        unanswered.clock.advance(by: GladiaLive.finishBudget - 0.1)
        XCTAssertTrue(unanswered.log.errors.isEmpty, "The whole budget is available to end_session")
        unanswered.clock.advance(by: 0.1)
        let result = await waiting.value
        XCTAssertEqual(result, "Confirmed.", "The latest draft is never promoted on failure")
        XCTAssertEqual(unanswered.log.errors.first as? GladiaStreamingError, .missingCompletion)
        XCTAssertEqual(unanswered.log.errors.count, 1)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testTransportFailuresAreConnectionLostWithConfirmedTextKept() async {
        let receiving = GladiaHarness()
        let socket = receiving.startOpen()
        socket.final("Before the drop.", id: "00-01")
        socket.failReceive()
        XCTAssertEqual(receiving.log.errors.first as? GladiaStreamingError, .connectionLost)
        let afterDrop = await receiving.client.finishAndWait()
        XCTAssertEqual(afterDrop, "Before the drop.")

        let sending = GladiaHarness()
        let sendSocket = sending.startOpen()
        sending.client.sendAudio(GladiaHarness.pcm(0))
        sending.client.sendAudio(GladiaHarness.pcm(1))
        sendSocket.completeSend(URLError(.networkConnectionLost))
        XCTAssertEqual(sending.log.errors.first as? GladiaStreamingError, .connectionLost)
        XCTAssertEqual(sendSocket.sentAudio.count, 1, "Nothing is sent after a rejected frame")

        let closing = GladiaHarness()
        let closingSocket = closing.startOpen()
        closing.client.sendAudio(GladiaHarness.pcm(0))
        closingSocket.completeSend()
        let finish = await beginFinish(closing)
        await waitUntil("stop_recording to reach the socket") { closingSocket.stopRecordingSent }
        closingSocket.completeSend()
        closingSocket.final("Almost.", id: "00-01")
        closingSocket.failReceive()
        let closed = await finish.value
        XCTAssertEqual(closed, "Almost.")
        XCTAssertEqual(closing.log.errors.first as? GladiaStreamingError, .connectionLost,
                       "A closure before end_session is not a completion")
    }

    func testServerErrorsAndAPrematureEndSessionEndTheRun() {
        let erroring = GladiaHarness()
        let socket = erroring.startOpen()
        socket.emit(#"{"type":"error","error":{"message":"Session expired"}}"#)
        XCTAssertEqual(erroring.log.errors.first as? GladiaStreamingError, .server(message: "Session expired"))
        XCTAssertEqual(socket.cancelCount, 1)

        let ended = GladiaHarness()
        let endedSocket = ended.startOpen()
        ended.client.sendAudio(GladiaHarness.pcm(0))
        endedSocket.endSession()
        XCTAssertEqual(ended.log.errors.first as? GladiaStreamingError, .unexpectedSessionEnd)
        ended.client.sendAudio(GladiaHarness.pcm(1))
        XCTAssertEqual(endedSocket.sentAudio.count, 1)
        XCTAssertEqual(ended.log.errors.count, 1)
    }

    func testByteAndChunkBudgetsFailOnceInsteadOfDroppingAudio() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        let chunk = GladiaHarness.pcm(0)
        let fit = 160_000 / chunk.count
        for _ in 0..<fit { harness.client.sendAudio(chunk) }
        XCTAssertTrue(harness.log.errors.isEmpty, "Five seconds of PCM, queued or in flight, is admitted")
        XCTAssertEqual(harness.client.admittedAudioBytes, 160_000)
        harness.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(harness.log.errors.map(\.localizedDescription),
                       [StreamingClientError.transportStalled(provider: "Gladia").localizedDescription])
        harness.client.sendAudio(chunk)
        XCTAssertEqual(harness.log.errors.count, 1, "Overflow is reported once")
        XCTAssertEqual(socket.sent.count, 1, "The held send was the only one in flight")
        XCTAssertEqual(socket.cancelCount, 1)

        let tiny = GladiaHarness()
        tiny.startOpen()
        for _ in 0..<GladiaLiveClient.maximumQueuedChunks { tiny.client.sendAudio(Data([0, 0])) }
        XCTAssertTrue(tiny.log.errors.isEmpty)
        XCTAssertEqual(tiny.client.admittedAudioChunks, GladiaLiveClient.maximumQueuedChunks)
        tiny.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(tiny.log.errors.count, 1, "The chunk count is bounded as well as the bytes")

        let waiting = GladiaHarness()
        waiting.start()
        for _ in 0..<fit { waiting.client.sendAudio(chunk) }
        waiting.client.sendAudio(chunk)
        XCTAssertEqual(waiting.log.errors.first as? GladiaStreamingError, .sessionNotReady,
                       "Audio held before the socket opens shares the same bounds")
    }

    func testErrorIsPublishedBeforeWaitersResumeAndItsHandlerMayRestart() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let log = harness.log
        let replacementLog = GladiaEventLog()
        client.start(
            onTranscript: { log.transcript($0, isFinal: $1) },
            onError: { error in
                log.fail(error)
                XCTAssertEqual(client.currentStage, .closed, "The failed run is retired before onError")
                client.start(
                    onTranscript: { replacementLog.transcript($0, isFinal: $1) },
                    onError: { replacementLog.fail($0) }
                )
                log.note("restarted")
            }
        )
        harness.sessions.grant()
        let socket = harness.socket
        socket.open()
        client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        socket.final("First run.", id: "00-01")
        let armed = expectation(description: "Finish armed its deadline")
        harness.clock.whenScheduled(GladiaLive.finishBudget) { armed.fulfill() }
        let finish = Task {
            let transcript = await client.finishAndWait()
            // Recorded by the waiter itself: the error must already be there.
            log.note("finish-returned")
            return transcript
        }
        await fulfillment(of: [armed], timeout: 5)
        socket.completeSend()
        socket.emit(#"{"type":"error","error":{"message":"Upstream failure"}}"#)
        let result = await finish.value
        XCTAssertEqual(result, "First run.")
        XCTAssertEqual(log.timeline, ["final:First run.", "error", "restarted", "finish-returned"])

        XCTAssertEqual(harness.sessions.requests.count, 2)
        let replacement = try XCTUnwrap(harness.sessions.requests.last)
        XCTAssertEqual(replacement.cancelCount, 0, "Nothing from the failed run cleans up its replacement")
        XCTAssertEqual(client.currentStage, .initiating)
        socket.final("Stale.", id: "00-09")
        socket.open()
        harness.clock.advance(by: GladiaLive.finishBudget)
        XCTAssertTrue(replacementLog.transcripts.isEmpty)
        XCTAssertTrue(replacementLog.errors.isEmpty)
        harness.sessions.grant(to: 1)
        harness.socket.open()
        client.sendAudio(GladiaHarness.pcm(1))
        XCTAssertEqual(harness.socket.sentAudio, [GladiaHarness.pcm(1)])
        client.cancel()
    }
}
