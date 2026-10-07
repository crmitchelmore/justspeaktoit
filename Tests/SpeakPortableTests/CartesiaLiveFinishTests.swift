import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Graceful finalisation: drain within its bound, exactly one
/// `{"type":"close"}`, then results until the server's normal closure or the
/// post-stop budget, returning the whole session; every failure is published
/// before the finish returns.
final class CartesiaLiveFinishTests: XCTestCase {
    private typealias Entry = CartesiaEventLog.Entry
    private let stalled = Entry.error("transportStalled(provider: \"Cartesia\")")

    func testFinishDrainsEveryFrameBeforeCloseAndCompletesOnTheServersClosure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let frames = (1...3).map { CartesiaLiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.turn("Before stop.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertEqual(fixture.socket.closeCommands, 0, "Close waits for every admitted frame")
        for _ in frames { fixture.socket.completeSend() }
        await fulfillment(of: [closeSent], timeout: 2)
        let expected = frames.map { StreamingWebSocketMessage.binary($0) } + [.text(CartesiaLiveProtocol.closeCommand)]
        XCTAssertEqual(fixture.socket.sent, expected)
        fixture.socket.completeSend()
        fixture.socket.turn("After stop.")
        fixture.socket.closeNormally()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Before stop. After stop.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Before stop.", final: false), .transcript("Before stop.", final: true),
            .finished("Before stop. After stop.")
        ], "Turns ending during the finish are returned once, not also delivered")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.clock.pending(CartesiaLiveClient.finishBudget), 1, "The drain bound never fired")
        XCTAssertEqual(
            fixture.clock.pending(CartesiaLiveFixture.postClose), 1, "Completion never waited for the post-stop budget"
        )
    }

    func testEmptySessionStaysEmpty() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.connected()
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [.finished(nil)])
    }

    func testFinishBeforeStartReturnsNilAndNeverConnects() async {
        let fixture = CartesiaLiveFixture()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.startAndOpen()
        defer { fixture.client.cancel() }
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Audio from before a finished idle client is not replayed")
    }

    func testFinishBeforeTheHandshakeSendsHeldAudioOnceTheSocketOpens() async {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        let frames = [CartesiaLiveFixture.frame(1), CartesiaLiveFixture.frame(2)]
        frames.forEach(fixture.client.sendAudio)
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertEqual(fixture.clock.pending(CartesiaLiveClient.finishBudget), 1, "The drain is bounded")
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        await fulfillment(of: [closeSent], timeout: 2)
        XCTAssertEqual(fixture.socket.binary, frames)
        fixture.socket.completeSend()
        fixture.socket.turn("Held words.")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Held words.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testFinishBeforeAHandshakeThatNeverCompletesFailsAtTheDrainBound() async {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.clock.fire(CartesiaLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady"), .finished(nil)])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testConcurrentFinishesShareOneCloseAndOneOutcome() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Shared.")
        let closeSent = fixture.expectClose(self)
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishes(2)
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.closeNormally()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Shared.", "Shared."])
        XCTAssertEqual(fixture.socket.closeCommands, 1)
        let repeated = await fixture.client.finishAndWait()
        XCTAssertEqual(repeated, "Shared.", "A later finish returns the same outcome")
        XCTAssertEqual(fixture.socket.closeCommands, 1)
    }

    func testClosureBeforeTheCloseSendCompletesIsSettledByThatCompletion() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.turn("Flushed.")
        fixture.socket.closeNormally()
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "The close command's own completion decides")
        fixture.socket.completeSend()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Flushed.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testCloseSendFailureAfterTheClosureIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        // Even a normal closure cannot complete a finish whose close command failed.
        fixture.socket.closeNormally()
        fixture.socket.completeSend(URLError(.notConnectedToInternet))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(
            Array(fixture.log.entries.suffix(2)),
            [CartesiaEventLog.urlError(.notConnectedToInternet), .finished("Confirmed.")]
        )
    }

    func testClosureBeforeCloseIsSentIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.closeByPeer()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(
            Array(fixture.log.entries.suffix(2)),
            [CartesiaEventLog.urlError(.networkConnectionLost), .finished("Confirmed.")]
        )
        XCTAssertEqual(fixture.socket.closeCommands, 0)
    }

    func testClosureWithATurnStillOpenReturnsItsWordsInTheWholeSession() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Unfinished thought")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Unfinished thought")
        XCTAssertTrue(fixture.log.errors.isEmpty)
        XCTAssertEqual(fixture.log.entries.last, .finished("Confirmed. Unfinished thought"))
        XCTAssertEqual(fixture.client.transcriptSnapshot(captureDuration: 0).segments.map(\.text), ["Confirmed."])
    }

    func testClosureAfterAStartedTurnWithoutWordsCompletesNormally() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("  ")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertTrue(fixture.log.errors.isEmpty, "A started turn that produced no words loses nothing")
    }

    func testClosureAfterAShownDraftReturnsItWithoutRepeatingIt() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Shown draft")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Shown draft")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Shown draft", final: false), .finished("Shown draft")
        ], "The draft is delivered once and returned with the session")
    }

    func testServerErrorDuringFinishReleasesWithheldWordsBeforeTheError() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Early.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.turn("Kept.")
        fixture.socket.serverError(status: 500, code: "internal", message: "Synthetic failure")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Early. Kept.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Early.", final: false), .transcript("Early.", final: true),
            .transcript("Kept.", final: true),
            .error("Cartesia(500): Synthetic failure"),
            .finished("Early. Kept.")
        ])
    }

    func testPostStopBudgetWithoutTheClosureReturnsTheWholeSession() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Trailing")
        fixture.clock.fire(CartesiaLiveClient.finishBudget)
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "Close was delivered, so the drain bound has nothing to end")
        fixture.clock.fire(CartesiaLiveFixture.postClose)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Trailing")
        XCTAssertTrue(fixture.log.errors.isEmpty, "The post-stop budget returns what the finish has")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.closeCommands, 1)
    }

    func testDrainThatNeverCompletesReportsAStalledTransport() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.clock.fire(CartesiaLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [stalled, .finished(nil)])
        XCTAssertEqual(fixture.socket.closeCommands, 0, "Close never overtakes an admitted frame")
    }
}
