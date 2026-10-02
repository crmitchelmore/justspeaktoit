import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Graceful finalisation of the shared xAI client: drain, `audio.done`,
/// `transcript.done` semantics, final-span identity, readiness during a
/// finish, bounded deadlines and cancellation.
final class XAISpeechToTextFinalisationTests: XCTestCase {
    func testFinishDrainsAdmittedAudioSendsAudioDoneAndReturnsTheAuthoritativeTranscript() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Hel", isFinal: false)
        socket.transcriptPartial("Hello.", isFinal: true, start: 0)
        let first = XAISpeechToTextLiveFixture.frame(1)
        let second = XAISpeechToTextLiveFixture.frame(2)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        let ending = expectation(description: "audio.done follows the drained audio")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertEqual(socket.binary, [first])
        socket.completeSend()
        XCTAssertEqual(socket.binary, [first, second])
        XCTAssertTrue(socket.controls.isEmpty, "audio.done waits behind every admitted frame")
        socket.completeSend()
        await fulfillment(of: [ending], timeout: 2)
        XCTAssertEqual(socket.audioDoneFrames.count, 1)
        socket.completeSend()
        socket.transcriptPartial("Second.", isFinal: true, start: 3)
        XCTAssertEqual(socket.cancels, 0, "A trailing chunk final cannot end the finish")
        socket.transcriptDone("Hello. Second. Third.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello. Second. Third.")
        XCTAssertEqual(fixture.events.texts, ["Hel", "Hello."], "Trailing text is returned once, not redelivered")
        XCTAssertEqual(fixture.events.finals, [false, true])
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testRepeatedSpansAreDroppedByIdentityAndAnEmptyCompletionKeepsLockedSpans() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        let locked = "The blue bicycle is parked beside the library."
        socket.transcriptPartial(locked, isFinal: true, speechFinal: false, start: 0.001)
        socket.transcriptPartial(locked, isFinal: true, speechFinal: true, start: 0.001)
        socket.transcriptPartial("Yes.", isFinal: true, start: 4)
        socket.transcriptPartial("Yes.", isFinal: true, start: 6)
        XCTAssertEqual(
            fixture.events.texts, [locked, "Yes.", "Yes."],
            "A restated span is dropped by identity; identical text at a new start is a genuine repeat"
        )
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.transcriptDone("")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "\(locked) Yes. Yes.")
        XCTAssertEqual(fixture.events.texts.count, 3)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishBeforeReadinessHoldsAudioUntilTranscriptCreatedThenDrains() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let held = XAISpeechToTextLiveFixture.frame(7)
        fixture.client.sendAudio(held)
        socket.open()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(XAISpeechToTextLiveClient.readyBudget)
        XCTAssertTrue(socket.binary.isEmpty, "Nothing leaves before transcript.created")
        XCTAssertTrue(socket.controls.isEmpty, "Not even audio.done")
        let ending = expectation(description: "audio.done follows the held audio")
        socket.fulfillOnAudioDone(ending)
        socket.transcriptCreated()
        XCTAssertEqual(socket.binary, [held])
        socket.completeSend()
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.transcriptDone("Opening words.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishWhoseSessionNeverBecomesReadyFailsVisiblyInsideTheReadyBudget() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        fixture.socket.open()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(XAISpeechToTextLiveClient.readyBudget)
        fixture.clock.fire(XAISpeechToTextLiveClient.readyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? XAISpeechToTextError, .sessionNotReady)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.socket.binary.isEmpty, "Held audio is never pushed to a session that is not ready")
        fixture.socket.transcriptCreated()
        XCTAssertTrue(fixture.socket.binary.isEmpty)
    }

    /// Only `transcript.done` completes a finish. A budget that elapses after
    /// `audio.done` left is a missing completion, and one that elapses while
    /// audio is still draining is a stall; both are published before the
    /// finish returns the locked spans, which are recovery material rather
    /// than a completed transcript.
    func testFinishDeadlineReportsAMissingCompletionAfterAudioDoneAndAStallBeforeIt() async {
        let incomplete = XAISpeechToTextLiveFixture()
        incomplete.start()
        incomplete.becomeReady()
        incomplete.socket.transcriptPartial("Best.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done")
        incomplete.socket.fulfillOnAudioDone(ending)
        let finish = Task { await incomplete.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        incomplete.socket.completeSend()
        // The audio.done send deadline and the finish deadline share a length.
        await incomplete.waitForScheduled(XAISpeechToTextLiveClient.finishBudget, count: 2)
        incomplete.clock.fire(XAISpeechToTextLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Best.", "The locked spans are returned for recovery")
        XCTAssertEqual(incomplete.events.errors.first as? XAISpeechToTextError, .missingCompletion)
        XCTAssertEqual(incomplete.events.errors.count, 1)
        XCTAssertEqual(incomplete.socket.cancels, 1)

        let stalled = XAISpeechToTextLiveFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        let stalledFinish = Task { await stalled.client.finishAndWait() }
        await stalled.waitForScheduled(XAISpeechToTextLiveClient.finishBudget, count: 2)
        stalled.clock.fire(XAISpeechToTextLiveClient.finishBudget)
        let stalledTranscript = await stalledFinish.value
        XCTAssertNil(stalledTranscript)
        XCTAssertEqual(stalled.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = stalled.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertTrue(stalled.socket.audioDoneFrames.isEmpty)
    }

    func testCancellingTheFinishTaskClosesTheSocketAndKeepsRetainedText() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.transcriptPartial("Retained.", isFinal: true, start: 0)
        let ending = expectation(description: "Finish begins")
        fixture.socket.fulfillOnAudioDone(ending)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Retained.")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testTranscriptDoneOutsideAFinishIsDeliveredOnceAndTheServerClosureIsNotAnError() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.transcriptPartial("Whole", isFinal: true, start: 0)
        fixture.socket.transcriptDone("Whole thing.")
        XCTAssertEqual(fixture.events.texts, ["Whole", "Whole thing."])
        XCTAssertEqual(fixture.events.finals, [true, true])
        fixture.socket.fail()
        XCTAssertTrue(fixture.events.errors.isEmpty, "The server closes the socket after transcript.done")
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Whole thing.")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testOfflineWaiterIsResolvedByTheDoneFrameAndFinishWithoutASocketReturnsFoldedFinals() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.client.beginSession(onTranscript: { [events = fixture.events] in events.transcript($0, final: $1) },
                                    onError: { [events = fixture.events] in events.fail($0) })
        fixture.client.ingest(#"{"type":"transcript.created"}"#)
        XCTAssertTrue(fixture.client.isSessionReady)
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        XCTAssertTrue(fixture.factory.sockets.isEmpty, "beginSession arms a run without a transport")
        fixture.client.ingest(#"{"type":"transcript.partial","text":"hello there","is_final":true,"start":0}"#)
        let started = Date()
        let replaced = await fixture.client.awaitFinalTranscript(budget: 5) {
            fixture.client.ingest(#"{"type":"transcript.done","text":"Hello there.","duration":2}"#)
        }
        XCTAssertEqual(replaced, "Hello there.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The done frame resolves the wait, not the budget")
        XCTAssertEqual(fixture.events.texts, ["hello there"], "The consumed completion is not redelivered")
        let closed = await fixture.client.finishAndWait()
        XCTAssertEqual(closed, "Hello there.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }
}
