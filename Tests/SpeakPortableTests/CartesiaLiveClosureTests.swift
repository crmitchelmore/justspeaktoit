import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The automatic-turns stream has no acknowledgement frame: after `close`, only
/// the server's affirmative normal closure (1000), reported by the transport
/// through `StreamingWebSocketCloseReporting`, completes a finish. A dropped
/// network or any other close code fails it, publishes the flushed words and
/// the error first, and still returns the confirmed text.
final class CartesiaLiveClosureTests: XCTestCase {
    func testNormalClosureAfterAValidFlushCompletesTheFinish() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.turn("Flushed.")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Flushed.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testNetworkLossAfterAValidFlushWithNoOpenTurnIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.turn("Flushed.")
        fixture.socket.closeByPeer()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Flushed.", "Confirmed words are still returned")
        XCTAssertEqual(Array(fixture.log.entries.suffix(3)), [
            .transcript("Flushed.", final: true), CartesiaEventLog.urlError(.networkConnectionLost),
            .finished("Confirmed. Flushed.")
        ], "A dropped connection is never reported as a completed transcript")
    }

    func testNetworkLossBeforeAnyTrailingTurnIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.closeByPeer()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(
            Array(fixture.log.entries.suffix(2)),
            [CartesiaEventLog.urlError(.networkConnectionLost), .finished("Confirmed.")]
        )
    }

    func testAbnormalPeerCloseAfterAValidFlushIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Partial")
        fixture.socket.turnEnd("Partial words.")
        fixture.socket.closeByPeer(code: 1_011)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Partial words.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(3)), [
            .transcript("Partial words.", final: true), .error("closed(code: 1011)"),
            .finished("Confirmed. Partial words.")
        ])
    }

    func testOnlyTheNormalCloseCodeCompletesAFinish() async {
        for code in [1_001, 1_005, 1_006, 1_008, 1_011, 4_000] {
            let fixture = CartesiaLiveFixture()
            let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
            fixture.socket.closeByPeer(code: code)
            let transcript = await finish.value
            XCTAssertEqual(transcript, "Confirmed.", "code \(code)")
            XCTAssertEqual(
                Array(fixture.log.entries.suffix(2)), [.error("closed(code: \(code))"), .finished("Confirmed.")],
                "code \(code)"
            )
        }
    }

    func testTruncatedTurnBeforeANormalClosureIsReportedWithItsDraft() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.turnStart()
        fixture.socket.turnUpdate("Cut off mid")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(3)), [
            .transcript("Cut off mid", final: false), .error("incompleteTurn"), .finished("Confirmed.")
        ])
    }

    func testNormalClosureBeforeCloseIsSentIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("closed(code: 1000)"), .finished("Confirmed.")])
        XCTAssertEqual(fixture.socket.closeCommands, 0, "Audio was still owed, so the stream cannot have ended")
    }

    /// `close` is claimed under the lock but reaches the socket only when the
    /// send loop runs, after the deferred work it waits behind (here, arming its
    /// send deadline). A normal closure that lands in between did not answer
    /// it: the server ended the stream on its own, so the finish fails.
    func testNormalClosureBeforeTheClaimedCloseReachesTheSocketIsAFailure() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Close claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: CartesiaLiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let finish = fixture.finish()
        await fulfillment(of: [claimed], timeout: 2)

        fixture.socket.closeNormally()
        XCTAssertEqual(fixture.log.errors.first as? CartesiaStreamingError, .closed(code: 1_000),
                       "A closure ahead of the handoff is not the answer to close")
        // Were the claimed close still handed over, it would complete at once.
        fixture.socket.setSendMode(.synchronous)
        release.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.", "The confirmed text is kept")
        XCTAssertEqual(fixture.socket.closeCommands, 0, "The failed run never hands the close command over")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("closed(code: 1000)"), .finished("Confirmed.")])
    }

    func testAbnormalClosureWhileCloseIsInFlightFailsOnceItCompletes() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.closeByPeer(code: 1_011)
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "The close command's completion settles the closure")
        fixture.socket.completeSend()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("closed(code: 1011)"), .finished("Confirmed.")])
    }

    func testStaleNormalClosureOfACancelledRunCompletesNothing() async {
        let fixture = CartesiaLiveFixture()
        let finish = await finishingFixture(fixture, confirmed: "Confirmed.")
        fixture.socket.keepCallbacksAfterCancel()
        fixture.client.cancel()
        let transcript = await finish.value
        fixture.socket.turn("Late.")
        fixture.socket.closeNormally()
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.log.entries.last, .finished("Confirmed."))
        XCTAssertTrue(fixture.log.errors.isEmpty)
        XCTAssertFalse(fixture.log.entries.contains(.transcript("Late.", final: true)))
    }

    func testStaleNormalClosureCannotCompleteAReplacementFinish() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let old = fixture.socket
        old.keepCallbacksAfterCancel()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.turn("Replacement.")
        let closeSent = expectation(description: "Replacement close command sent")
        replacement.onSend { message in
            if case .text(let text) = message, text == CartesiaLiveProtocol.closeCommand { closeSent.fulfill() }
        }
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        replacement.completeSend()
        old.closeNormally()
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "Only the replacement's own closure can complete it")
        replacement.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Replacement.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    /// Opens a session with one confirmed turn and finishes it up to the
    /// point where `close` has been delivered and the server's closure is due.
    private func finishingFixture(_ fixture: CartesiaLiveFixture, confirmed: String) async -> Task<String?, Never> {
        fixture.startAndOpen()
        fixture.socket.turn(confirmed)
        let closeSent = fixture.expectClose(self)
        let finish = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        return finish
    }
}
