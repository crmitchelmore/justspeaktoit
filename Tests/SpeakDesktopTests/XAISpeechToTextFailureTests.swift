import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Failure delivery of the shared xAI client: exactly one `onError`, published
/// before any finish waiter resumes, with late transport callbacks isolated.
final class XAISpeechToTextFailureTests: XCTestCase {
    func testSendFailureIsPublishedOnceAndLaterFramesCannotReviveTheRun() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Kept.", isFinal: true, start: 0)
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(fixture.client.isSessionReady)
        socket.transcriptPartial("Late.", isFinal: true, start: 2)
        socket.transcriptDone("Late done.")
        socket.fail()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(2))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.texts, ["Kept."])
        XCTAssertEqual(socket.binary.count, 1)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Kept.", "Text received before the failure stays available")
    }

    func testServerErrorDuringFinishIsDeliveredOnceBeforeTheWaiterResumes() async {
        await exerciseFailureOrdering { $0.xaiError("rate limit exceeded") }
    }

    /// The server closes the socket only after `transcript.done`, so a closure
    /// once `audio.done` has left but before that frame is still a failure.
    func testClosureAfterAudioDoneWithoutTranscriptDoneIsDeliveredOnceBeforeTheWaiterResumes() async {
        await exerciseFailureOrdering { $0.fail() }
    }

    private func exerciseFailureOrdering(trigger: @escaping @Sendable (AssemblyAITestSocket) -> Void) async {
        let fixture = XAISpeechToTextLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered on the provider queue")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = XAIFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = fixture.socket
        fixture.becomeReady()
        old.transcriptPartial("Saved.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done proves the finish waiter is registered")
        old.fulfillOnAudioDone(ending)
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [ending], timeout: 2)
        old.completeSend()
        DispatchQueue.global().async { trigger(old) }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.", "The locked spans are returned for recovery after the error")
        XCTAssertEqual(old.cancels, 1)
        assertReplacementAcceptsAudio(fixture)
    }

    private func assertReplacementAcceptsAudio(_ fixture: XAISpeechToTextLiveFixture) {
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.transcriptCreated()
        fixture.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        fixture.client.cancel()
    }

    func testErrorFrameAfterAudioDoneEndsTheFinishOnceAndLateFramesAreIgnored() async {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Saved.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.xaiError("backend unavailable")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Saved.")
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.errors.first as? XAISpeechToTextError, .server(message: "backend unavailable"))
        socket.transcriptDone("Late.")
        socket.fail()
        fixture.clock.fire(XAISpeechToTextLiveClient.finishBudget)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.texts, ["Saved."])
        XCTAssertEqual(socket.cancels, 1)
        let again = await fixture.client.finishAndWait()
        XCTAssertEqual(again, "Saved.", "A closed run answers a second finish at once with the same text")
    }

    /// A closure during a finish is a failure until `transcript.done` has
    /// arrived, whether audio is still draining or `audio.done` has already
    /// left; the retained text comes back either way, after the error.
    func testTransportClosureDuringFinishIsAFailureUntilTranscriptDoneArrives() async {
        let early = XAISpeechToTextLiveFixture()
        early.start()
        early.becomeReady()
        early.socket.transcriptPartial("Partial.", isFinal: true, start: 0)
        early.client.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        let finish = Task { await early.client.finishAndWait() }
        await early.waitForScheduled(XAISpeechToTextLiveClient.finishBudget, count: 2)
        early.socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Partial.")
        XCTAssertEqual(early.events.errors.count, 1, "Audio still queued was lost, which the user must hear about")
        XCTAssertTrue(early.socket.audioDoneFrames.isEmpty)

        let late = XAISpeechToTextLiveFixture()
        late.start()
        late.becomeReady()
        late.socket.transcriptPartial("Incomplete.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done")
        late.socket.fulfillOnAudioDone(ending)
        let lateFinish = Task { await late.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        late.socket.completeSend()
        late.socket.fail()
        let lateTranscript = await lateFinish.value
        XCTAssertEqual(lateTranscript, "Incomplete.", "Retained for recovery, not as a completed transcript")
        XCTAssertEqual(late.events.errors.count, 1, "No transcript.done arrived, so the closure is not benign")
        XCTAssertEqual((late.events.errors.first as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(late.socket.cancels, 1)
    }

    func testServerErrorFramesAreClassifiedBeforeTheyReachTheHost() {
        let fixture = XAISpeechToTextLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.xaiError("Invalid API key")
        XCTAssertEqual(
            fixture.events.errors.first?.localizedDescription,
            StreamingClientError.invalidAPIKey(provider: "xAI").localizedDescription
        )
        XCTAssertEqual(fixture.socket.cancels, 1)
        let quota = XAISpeechToTextLiveFixture()
        quota.start()
        quota.becomeReady()
        quota.socket.xaiError("no credit remaining")
        XCTAssertEqual(
            quota.events.errors.first as? XAISpeechToTextError, .quotaExceeded(message: "no credit remaining")
        )
    }
}

private final class XAIFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
