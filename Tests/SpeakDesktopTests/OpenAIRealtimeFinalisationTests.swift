import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class OpenAIRealtimeFinalisationTests: XCTestCase {
    func testFinishDrainsAdmittedAudioCommitsThenWaitsForTheCommittedItem() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.delta("Hello", item: "item_1")
        socket.completed("Hello.", item: "item_1")
        let first = Data(repeating: 1, count: 4_800)
        let second = Data(repeating: 2, count: 4_800)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        let committing = expectation(description: "Commit follows the drained audio")
        socket.fulfillOnCommit(committing)
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertEqual(socket.audio, [first])
        socket.completeSend()
        XCTAssertEqual(socket.audio, [first, second])
        socket.completeSend()
        await fulfillment(of: [committing], timeout: 2)
        XCTAssertEqual(socket.types.last, "input_audio_buffer.commit")
        socket.completeSend()
        socket.committed("item_2", previous: "item_1")
        socket.completed("Hello again.", item: "item_1")
        XCTAssertEqual(socket.cancels, 0, "A completion for an earlier item cannot end the finish")
        socket.delta("Second", item: "item_2")
        socket.completed("Second.", item: "item_2")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello again. Second.")
        XCTAssertEqual(fixture.events.texts, ["Hello", "Hello."], "Trailing text is returned once, not redelivered")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testShortInputIsPaddedToTheMinimumCommitDurationBeforeCommit() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        let tail = Data(repeating: 5, count: 1_000)
        fixture.client.sendAudio(tail)
        socket.completeSend()
        let committing = expectation(description: "Commit follows the padding")
        socket.fulfillOnCommit(committing)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.audio.count == 2 }
        XCTAssertEqual(socket.audio[1].count, OpenAIRealtimeProtocol.minimumCommitBytes - tail.count)
        XCTAssertTrue(socket.audio[1].allSatisfy { $0 == 0 })
        socket.completeSend()
        await fulfillment(of: [committing], timeout: 2)
        socket.completeSend()
        socket.committed("item_1")
        socket.completed("Hi.", item: "item_1")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hi.")
    }

    func testNoInputFinishSendsNoCommitReportsNoErrorAndReturnsNil() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.socket.types, ["session.update"])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testStopBeforeReadyKeepsOpeningAudioAndCommitsAfterTheAcknowledgement() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let opening = Data(repeating: 42, count: 4_800)
        fixture.client.sendAudio(opening)
        let committing = expectation(description: "Commit follows the opening audio")
        socket.fulfillOnCommit(committing)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(OpenAIRealtimeLiveClient.finishReadyBudget)
        XCTAssertTrue(socket.controls.isEmpty)
        fixture.becomeReady()
        XCTAssertEqual(socket.audio, [opening])
        socket.completeSend()
        await fulfillment(of: [committing], timeout: 2)
        socket.completeSend()
        socket.committed("item_1")
        socket.completed("Opening words.", item: "item_1")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
    }

    func testStopBeforeReadyFailsVisiblyWhenTheAcknowledgementNeverArrives() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(OpenAIRealtimeLiveClient.finishReadyBudget)
        fixture.clock.fire(OpenAIRealtimeLiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? OpenAIRealtimeStreamingError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testFinaliseDeadlineReturnsTheBestAvailableTextWhenNoCompletionArrives() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.delta("Hello", item: "item_1")
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.types.last == "input_audio_buffer.commit" }
        socket.completeSend()
        let budget = fixture.client.finalizeBudget
        XCTAssertEqual(
            budget,
            ModelCatalog.liveCapabilities(
                for: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
            ).postStopFinalizeBudget
        )
        await fixture.waitForScheduled(budget)
        fixture.clock.fire(budget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testFinishDeadlineFailsAStalledDrainVisibly() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(OpenAIRealtimeLiveClient.finishDeadline)
        fixture.clock.fire(OpenAIRealtimeLiveClient.finishDeadline)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testDeltasAppendCompletionsReplaceAndCommitOrderWinsOverArrivalOrder() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.committed("item_b", previous: "item_a")
        socket.delta("wor", item: "item_b")
        socket.delta("ld", item: "item_b")
        socket.delta("Hello", item: "item_a")
        socket.completed("World.", item: "item_b")
        socket.completed("Hello.", item: "item_a")
        socket.completed("Hello.", item: "item_a")
        XCTAssertEqual(
            fixture.events.texts,
            ["wor", "world", "Hello world", "Hello World.", "Hello. World.", "Hello. World."]
        )
        XCTAssertEqual(fixture.events.finals, [false, false, false, true, true, true])
        fixture.client.cancel()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Hello. World.")
    }

    func testCancelAbortsWithoutCommitAndPreservesReceivedText() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.delta("Retained", item: "item_1")
        fixture.client.cancel()
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(socket.types.contains("input_audio_buffer.commit"))
        socket.completeSend(URLError(.cancelled))
        fixture.clock.fire(OpenAIRealtimeLiveClient.sendDeadline)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Retained")
        XCTAssertEqual(fixture.factory.sockets.count, 1, "No reconnect after stopping")
    }

    func testGracefulStopDeliversCallbacksWhileFinishingAndClosesOnCompletion() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.completeSend()
        fixture.client.stop()
        XCTAssertEqual(socket.types.last, "input_audio_buffer.commit")
        socket.completeSend()
        socket.committed("item_1")
        socket.delta("Final", item: "item_1")
        socket.completed("Final words.", item: "item_1")
        XCTAssertEqual(fixture.events.texts, ["Final", "Final words."])
        XCTAssertEqual(fixture.events.finals, [false, true])
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishAfterACompletedCanonicalCommitReturnsWithoutWaiting() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.startCanonical()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.completeSend()
        fixture.client.commitInputBuffer()
        socket.completeSend()
        socket.committed("item_1")
        socket.completed("Done.", item: "item_1")
        XCTAssertEqual(socket.cancels, 0, "A canonical commit leaves closing to the controller")
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Done.")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertEqual(fixture.canonical.all, [.sessionReady, .completed("Done.", itemId: "item_1")])
    }

    func testContractFlagsAndIdleFinish() async {
        let client = OpenAIRealtimeLiveClient(apiKey: "k", model: "gpt-live-transcribe")
        XCTAssertEqual(client.finalShape, .cumulativeTranscript)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
        let transcript = await client.finishAndWait()
        XCTAssertNil(transcript)
    }
}
