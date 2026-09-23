import Foundation
import XCTest
@testable import SpeakCore

final class OpenAIRealtimeCommitIdentityTests: XCTestCase {
    func testLatePriorCompletionBeforeFinalAcknowledgementCannotFinishTheLastTurn() async {
        let fixture = readyFixture()
        sendTurnAndCommit(fixture)
        fixture.socket.committed("A")
        let finish = await beginFinalTurn(fixture)
        fixture.socket.completed("First turn.", item: "A")
        XCTAssertEqual(fixture.socket.cancels, 0)
        fixture.socket.completeSend()
        fixture.socket.committed("B", previous: "A")
        fixture.socket.completed("Last turn.", item: "B")
        let result = await finish.value
        XCTAssertEqual(result, "First turn. Last turn.")
    }

    func testDelayedPriorAcknowledgementIsNotAssignedToTheFinalCommit() async {
        let fixture = readyFixture()
        sendTurnAndCommit(fixture)
        let finish = await beginFinalTurn(fixture)
        fixture.socket.completeSend()
        fixture.socket.committed("A")
        fixture.socket.completed("First.", item: "A")
        XCTAssertEqual(fixture.socket.cancels, 0)
        fixture.socket.committed("A") // A duplicate must not consume B's acknowledgement slot.
        fixture.socket.committed("B", previous: "A")
        fixture.socket.completed("Last.", item: "B")
        let result = await finish.value
        XCTAssertEqual(result, "First. Last.")
    }

    func testFinalItemCompletingFirstStillWaitsForTheEarlierOutstandingItem() async {
        let fixture = readyFixture()
        sendTurnAndCommit(fixture)
        fixture.socket.committed("A")
        let finish = await beginFinalTurn(fixture)
        fixture.socket.completeSend()
        fixture.socket.committed("B", previous: "A")
        fixture.socket.completed("Last.", item: "B")
        XCTAssertEqual(fixture.socket.cancels, 0)
        fixture.socket.completed("First.", item: "A")
        let result = await finish.value
        XCTAssertEqual(result, "First. Last.")
    }

    func testCompletionBeforeItsAcknowledgementWaitsForIdentityThenFinishes() async {
        let fixture = readyFixture()
        let finish = await beginFinalTurn(fixture)
        fixture.socket.completeSend()
        fixture.socket.completed("Done.", item: "B")
        XCTAssertEqual(fixture.socket.cancels, 0, "A completion alone does not identify the final commit")
        fixture.socket.committed("B")
        let result = await finish.value
        XCTAssertEqual(result, "Done.")
    }

    func testEarlierCommitSendDoesNotArmFinalTimerBeforeFinalAudioDrains() async {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data(count: 4_800))
        fixture.socket.completeSend()
        fixture.client.commitInputBuffer() // A remains in flight.
        fixture.client.sendAudio(Data(count: 4_800))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(OpenAIRealtimeLiveClient.finishDeadline)
        fixture.socket.completeSend() // A completed; B PCM is now in flight.
        XCTAssertEqual(fixture.clock.pending(fixture.client.finalizeBudget), 0)
        fixture.clock.fire(fixture.client.finalizeBudget)
        XCTAssertEqual(fixture.socket.cancels, 0)
        fixture.socket.completeSend() // B PCM completed; final commit is now in flight.
        XCTAssertEqual(fixture.clock.pending(fixture.client.finalizeBudget), 0)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.clock.pending(fixture.client.finalizeBudget), 1)
        fixture.socket.committed("A")
        fixture.socket.committed("B", previous: "A")
        fixture.socket.completed("First.", item: "A")
        fixture.socket.completed("Last.", item: "B")
        let result = await finish.value
        XCTAssertEqual(result, "First. Last.")
    }

    func testKnownPriorCommitErrorDoesNotConsumeTheFinalAcknowledgement() async throws {
        let fixture = readyFixture()
        sendTurnAndCommit(fixture)
        let eventID = try XCTUnwrap(fixture.socket.objects.last?["event_id"] as? String)
        let finish = await beginFinalTurn(fixture)
        fixture.socket.completeSend()
        let error = try JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["code": "invalid_request_error", "message": "Prior commit", "event_id": eventID]
        ])
        fixture.socket.emit(try XCTUnwrap(String(data: error, encoding: .utf8)))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 0)
        fixture.socket.committed("B")
        fixture.socket.completed("Last.", item: "B")
        let result = await finish.value
        XCTAssertEqual(result, "Last.")
    }

    private func readyFixture() -> OpenAIRealtimeLiveFixture {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        return fixture
    }

    private func sendTurnAndCommit(_ fixture: OpenAIRealtimeLiveFixture) {
        fixture.client.sendAudio(Data(count: 4_800))
        fixture.socket.completeSend()
        fixture.client.commitInputBuffer()
        fixture.socket.completeSend()
    }

    private func beginFinalTurn(_ fixture: OpenAIRealtimeLiveFixture) async -> Task<String?, Never> {
        fixture.client.sendAudio(Data(count: 4_800))
        fixture.socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(OpenAIRealtimeLiveClient.finishDeadline)
        return finish
    }
}
