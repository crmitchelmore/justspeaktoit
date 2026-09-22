import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Finish sequencing of the shared Azure Voice Live client: drain, commit,
/// barrier, item bookkeeping and the one whole-finish budget.
final class AzureVoiceLiveFinalisationTests: XCTestCase {
    func testAHealthyFinishDrainsAudioThenCommitsThenSendsTheBarrierAndReturnsAtOnce() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        let finish = await beginFinishBehindSends(fixture)
        XCTAssertEqual(socket.types.last, "input_audio_buffer.append", "Admitted audio leaves before the commit")
        fixture.completeSends(4)
        XCTAssertEqual(socket.types, [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.append",
            "input_audio_buffer.commit", "session.update"
        ])
        let ids = fixture.client.currentEventIDs
        XCTAssertEqual(socket.azureCommits.first?["event_id"] as? String, ids.commit)
        let barrier = socket.azureSessionUpdates.last
        XCTAssertEqual(barrier?["event_id"] as? String, ids.barrier)
        XCTAssertEqual(barrier?["session"] as? [String: [String]], ["modalities": ["text"]])
        socket.committed("item-1")
        socket.delta("Hel", item: "item-1")
        socket.completed("Hello.", item: "item-1")
        XCTAssertEqual(socket.cancels, 0, "The barrier has not been acknowledged yet")
        socket.azureAcknowledge()
        // The fake clock never fires on its own, so returning here proves the
        // finish ended on the acknowledgement rather than on its deadline.
        let text = await finish.value
        XCTAssertEqual(text, "Hello.")
        XCTAssertTrue(fixture.events.texts.isEmpty, "The finish returns the transcript; nothing is delivered twice")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(socket.controls.contains { $0.contains("response.create") })
    }

    func testFinishingWhileConnectingHoldsAudioUntilReadyThenCommits() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        let finish = await beginFinishBehindSends(fixture)
        let socket = fixture.socket
        XCTAssertTrue(socket.controls.isEmpty)
        fixture.becomeReady()
        fixture.completeSends(4)
        XCTAssertEqual(socket.audio, [AzureVoiceLiveFixture.frame(0), AzureVoiceLiveFixture.frame(1)])
        XCTAssertEqual(Array(socket.types.suffix(2)), ["input_audio_buffer.commit", "session.update"])
        socket.committed("held")
        socket.completed("Held.", item: "held")
        socket.azureAcknowledge()
        let text = await finish.value
        XCTAssertEqual(text, "Held.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testItemsServerVADAnnouncedBeforeTheBarrierAreAwaitedInItemOrder() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        socket.committed("vad-1")
        socket.delta("First", item: "vad-1")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        socket.completeSend()
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        socket.committed("final-2")
        socket.completed("Second.", item: "final-2")
        socket.azureAcknowledge()
        XCTAssertEqual(socket.cancels, 0, "vad-1 is still being transcribed")
        XCTAssertEqual(fixture.client.pendingFinishCount, 1)
        socket.completed("First.", item: "vad-1")
        let text = await finish.value
        XCTAssertEqual(text, "First. Second.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testAnEmptyFinalCommitNeverEndsTheFinishOnItsOwn() async {
        for correlated in [true, false] {
            let fixture = AzureVoiceLiveFixture()
            fixture.start()
            fixture.becomeReady()
            let socket = fixture.socket
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            socket.completeSend()
            socket.committed("vad-1")
            let finish = await beginFinish(fixture)
            fixture.completeSends(2)
            let commitID = fixture.client.currentEventIDs.commit
            socket.azureError(code: AzureVoiceLiveProtocol.commitEmptyCode, eventID: correlated ? commitID : nil)
            XCTAssertTrue(fixture.events.errors.isEmpty, "Server VAD had already committed the audio")
            socket.azureAcknowledge()
            XCTAssertEqual(socket.cancels, 0, "Announced items still settle before the finish returns")
            socket.completed("Only.", item: "vad-1")
            let text = await finish.value
            XCTAssertEqual(text, "Only.")
            XCTAssertTrue(fixture.events.errors.isEmpty)
        }
    }

    func testCompletionsInAnyOrderKeepItemOrderAndDuplicatesNeverDoubleText() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        ["a", "b", "c"].forEach { socket.committed($0) }
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        socket.azureError(code: AzureVoiceLiveProtocol.commitEmptyCode, eventID: fixture.client.currentEventIDs.commit)
        socket.azureAcknowledge()
        socket.completed("Three.", item: "c")
        socket.completed("Yes.", item: "a")
        socket.completed("Yes.", item: "a")
        socket.transcriptionFailed(item: "a", message: "Late failure for a settled item")
        socket.completed("Yes.", item: "b")
        let text = await finish.value
        XCTAssertEqual(text, "Yes. Yes. Three.", "Two identical utterances stay two; a repeated event adds nothing")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAFailedTurnKeepsLaterUtterancesButEveryTurnFailingIsVisible() async {
        let kept = AzureVoiceLiveFixture()
        kept.start()
        kept.becomeReady()
        kept.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        kept.socket.completeSend()
        kept.socket.committed("a")
        kept.socket.transcriptionFailed(item: "a", message: "Synthetic")
        kept.socket.committed("b")
        kept.socket.completed("Still here.", item: "b")
        XCTAssertEqual(kept.events.texts, ["Still here."])
        let keptText = await finishWithEmptyCommit(kept)
        XCTAssertEqual(keptText, "Still here.")
        XCTAssertTrue(kept.events.errors.isEmpty, "A single failed turn is not a session failure")

        let failed = AzureVoiceLiveFixture()
        failed.start()
        failed.becomeReady()
        failed.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        failed.socket.completeSend()
        failed.socket.committed("a")
        failed.socket.transcriptionFailed(item: "a", message: "Synthetic")
        let nothing = await finishWithEmptyCommit(failed)
        XCTAssertNil(nothing)
        XCTAssertEqual(
            failed.events.errors.map(\.localizedDescription),
            [AzureSpeechError.transcriptionFailed.localizedDescription]
        )
    }

    func testSilenceReturnsNothingWithoutAnError() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data(count: AzureVoiceLiveProtocol.frameBytes))
        fixture.socket.completeSend()
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        fixture.socket.committed("quiet")
        fixture.socket.completed("", item: "quiet")
        fixture.socket.azureAcknowledge()
        let text = await finish.value
        XCTAssertNil(text)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAFinishWithNoAudioReturnsAtOnceWithoutARoundTrip() async {
        let ready = AzureVoiceLiveFixture()
        ready.start()
        ready.becomeReady()
        let readyText = await ready.client.finishAndWait()
        XCTAssertNil(readyText)
        XCTAssertEqual(ready.socket.types, ["session.update"])
        XCTAssertEqual(ready.socket.cancels, 1)

        let connecting = AzureVoiceLiveFixture()
        connecting.start()
        let connectingText = await connecting.client.finishAndWait()
        XCTAssertNil(connectingText)
        XCTAssertTrue(connecting.socket.controls.isEmpty)
        XCTAssertEqual(connecting.socket.cancels, 1)
        XCTAssertTrue(ready.events.errors.isEmpty && connecting.events.errors.isEmpty)
    }

    func testAMissingFinalIsReportedAtTheBudgetWithConfirmedTextOnly() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        socket.committed("a")
        socket.completed("Kept.", item: "a")
        socket.committed("b")
        socket.delta("draft words", item: "b")
        XCTAssertEqual(fixture.events.texts.last, "Kept. draft words")
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        socket.azureError(code: AzureVoiceLiveProtocol.commitEmptyCode, eventID: fixture.client.currentEventIDs.commit)
        socket.azureAcknowledge()
        XCTAssertEqual(socket.cancels, 0)
        fixture.clock.fire(fixture.finishBudget)
        let text = await finish.value
        XCTAssertEqual(text, "Kept.", "The draft stays the host's; the finish returns confirmed text only")
        XCTAssertEqual(fixture.events.errors.map { $0 as? AzureVoiceLiveError }, [.missingFinalTranscript])
        XCTAssertEqual(socket.cancels, 1)
    }

    func testTheBudgetNamesAnUnreadySessionOrAStalledDrain() async {
        let unready = AzureVoiceLiveFixture()
        unready.start()
        unready.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let unreadyFinish = await beginFinishBehindSends(unready)
        unready.clock.fire(unready.finishBudget)
        _ = await unreadyFinish.value
        XCTAssertEqual(unready.events.errors.map { $0 as? AzureVoiceLiveError }, [.sessionNotReady])

        let stalled = AzureVoiceLiveFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        stalled.socket.completeSend()
        let stalledFinish = await beginFinish(stalled)
        stalled.clock.fire(stalled.finishBudget)
        _ = await stalledFinish.value
        XCTAssertEqual(
            stalled.events.errors.map(\.localizedDescription),
            [StreamingClientError.transportStalled(provider: "Azure Speech").localizedDescription]
        )
    }

    func testConcurrentAndRepeatedFinishesShareOneResult() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        let first = await beginFinish(fixture)
        let second = fixture.finish()
        await fixture.waitForFinishers(2)
        fixture.completeSends(2)
        XCTAssertEqual(socket.azureCommits.count, 1, "A second caller joins the finish; it does not repeat it")
        socket.committed("a")
        socket.completed("Once.", item: "a")
        socket.azureAcknowledge()
        let firstText = await first.value
        let secondText = await second.value
        let thirdText = await fixture.client.finishAndWait()
        XCTAssertEqual([firstText, secondText, thirdText], ["Once.", "Once.", "Once."])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testARefusedBarrierStillEstablishesOrdering() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        socket.committed("a")
        socket.completed("Done.", item: "a")
        socket.azureError(code: "invalid_request_error", eventID: fixture.client.currentEventIDs.barrier)
        let text = await finish.value
        XCTAssertEqual(text, "Done.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testOtherServerErrorsEndTheSessionWithTheirBoundedCode() async {
        let refused = AzureVoiceLiveFixture()
        refused.start()
        refused.becomeReady()
        refused.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        refused.socket.completeSend()
        let finish = await beginFinish(refused)
        refused.completeSends(2)
        refused.socket.azureError(code: "invalid_value", eventID: refused.client.currentEventIDs.commit)
        _ = await finish.value
        XCTAssertEqual(refused.events.errors.map { $0 as? AzureVoiceLiveError }, [.serverError(code: "invalid_value")])

        let recording = AzureVoiceLiveFixture()
        recording.start()
        recording.becomeReady()
        recording.socket.azureError(code: AzureVoiceLiveProtocol.commitEmptyCode)
        recording.socket.azureError(code: "rate_limit_exceeded")
        XCTAssertEqual(
            recording.events.errors.map { $0 as? AzureVoiceLiveError },
            [.serverError(code: AzureVoiceLiveProtocol.commitEmptyCode)],
            "An empty commit this client did not send is not finalisation bookkeeping"
        )

        let malformed = AzureVoiceLiveFixture()
        malformed.start()
        malformed.becomeReady()
        malformed.socket.emit("not json")
        XCTAssertEqual(
            malformed.events.errors.map(\.localizedDescription), [AzureSpeechError.invalidResponse.localizedDescription]
        )
    }

    // MARK: - Helpers

    /// Starts a finish whose commit can leave at once (nothing is in flight)
    /// and waits until it is on the wire. The finish budget is armed in the
    /// same step, before that send, so it is armed too.
    private func beginFinish(_ fixture: AzureVoiceLiveFixture) async -> Task<String?, Never> {
        let committed = expectation(description: "Commit handed to the transport")
        fixture.socket.fulfillOnCommit(committed)
        let finish = fixture.finish()
        await fulfillment(of: [committed], timeout: 2)
        fixture.socket.onSend = nil
        return finish
    }

    /// Starts a finish that must queue behind a send in flight or an
    /// unacknowledged session, so it sends nothing yet, and waits until its
    /// budget is armed.
    private func beginFinishBehindSends(_ fixture: AzureVoiceLiveFixture) async -> Task<String?, Never> {
        let armed = fixture.clock.pending(fixture.finishBudget)
        let finish = fixture.finish()
        await fixture.settle { fixture.clock.pending(fixture.finishBudget) > armed }
        return finish
    }

    /// Server VAD committed everything: the final commit is empty, then the
    /// barrier is acknowledged.
    private func finishWithEmptyCommit(_ fixture: AzureVoiceLiveFixture) async -> String? {
        let finish = await beginFinish(fixture)
        fixture.completeSends(2)
        fixture.socket.azureError(
            code: AzureVoiceLiveProtocol.commitEmptyCode, eventID: fixture.client.currentEventIDs.commit
        )
        fixture.socket.azureAcknowledge()
        return await finish.value
    }
}
