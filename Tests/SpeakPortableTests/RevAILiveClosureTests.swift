import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Rev.ai answers `EOS` with the final hypothesis and a close message. Only the
/// normal closure (1000), reported by the transport through
/// `StreamingWebSocketCloseReporting` after `EOS` was delivered, completes a
/// finish. A dropped network, any other status, a closure `EOS` did not cause,
/// or a failed send fails it: the flushed words and the error are published
/// first, and the confirmed text is still returned.
final class RevAILiveClosureTests: XCTestCase {
    func testEveryOtherEndAfterEOSIsAFailureThatKeepsTheConfirmedText() async {
        let cases: [(close: Int?, error: String)] = [
            (nil, RevAIEventLog.describe(URLError(.networkConnectionLost))),
            (1_001, "closed(closeCode: 1001)"), (1_005, "closed(closeCode: 1005)"),
            (1_006, "closed(closeCode: 1006)"), (1_011, "closed(closeCode: 1011)"),
            (4_000, "closed(closeCode: 4000)"), (4_003, "insufficientCredits"),
            (4_010, "temporarilyUnavailable(closeCode: 4010)")
        ]
        for (close, error) in cases {
            let fixture = RevAILiveFixture()
            let finish = await finishingAfterEOS(fixture, confirmed: "Confirmed.")
            if let close { fixture.socket.closeByPeer(code: close) } else { fixture.socket.closeByPeer() }
            let transcript = await finish.value
            let label = String(describing: close)
            XCTAssertEqual(transcript, "Confirmed.", label)
            XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error(error), .finished("Confirmed.")], label)
        }
    }

    func testTrailingFinalBeforeADroppedConnectionReachesTheHostBeforeTheError() async {
        let fixture = RevAILiveFixture()
        let finish = await finishingAfterEOS(fixture, confirmed: "Confirmed.")
        fixture.socket.revAIFinal("Flushed.")
        fixture.socket.closeByPeer()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed. Flushed.", "A final is confirmed text even when the close is missing")
        XCTAssertEqual(Array(fixture.log.entries.suffix(3)), [
            .transcript("Flushed.", final: true), RevAIEventLog.urlError(.networkConnectionLost),
            .finished("Confirmed. Flushed.")
        ], "A dropped connection is never reported as a completed transcript")
    }

    func testNormalClosureWhileStreamingIsAnEarlyEndNotACompletion() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Early.")
        fixture.socket.closeNormally()
        XCTAssertEqual(fixture.log.entries, [.transcript("Early.", final: true), .error("unexpectedCompletion")])
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Early.")
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0)
    }

    func testNormalClosureWhileAudioIsStillOwedIsAFailure() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.socket.revAIFinal("Confirmed.")
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("unexpectedCompletion"), .finished("Confirmed.")])
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0, "Audio was still owed, so the stream cannot have ended")
    }

    /// `EOS` is claimed under the lock but reaches the socket only when the
    /// send loop runs, after the deferred work it waits behind (here, arming
    /// the finish's deadlines, which are held). A normal closure that lands in
    /// between did not answer it: the server ended the stream on its own, so
    /// the finish fails.
    func testNormalClosureBeforeTheClaimedEOSReachesTheSocketIsAFailure() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "EOS claimed; the work deferred before its handoff is running")
        fixture.clock.holdNextSchedule(of: RevAILiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let finish = fixture.finish()
        await fulfillment(of: [claimed], timeout: 2)

        fixture.socket.closeNormally()
        XCTAssertEqual(fixture.log.errors.first as? RevAILiveError, .unexpectedCompletion,
                       "A closure ahead of the handoff is not the answer to EOS")
        // Were the claimed EOS still handed over, it would complete at once.
        fixture.socket.setSendMode(.synchronous)
        release.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.", "The confirmed text is kept")
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0, "The failed run never hands EOS over")
        XCTAssertEqual(
            Array(fixture.log.entries.suffix(2)), [.error("unexpectedCompletion"), .finished("Confirmed.")]
        )
    }

    func testFailedEOSSendIsNeverCompletedByTheClosureThatFollowsIt() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.closeNormally()
        fixture.socket.completeSend(URLError(.notConnectedToInternet))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("unexpectedCompletion"), .finished("Confirmed.")],
                       "EOS never reached the server, so its closure cannot have answered it")
    }

    func testFailedEOSSendWithoutAClosureReportsItsOwnErrorAfterTheGrace() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertTrue(fixture.log.errors.isEmpty, "The receive side may still name the cause")
        XCTAssertEqual(fixture.client.pendingFinishes, 1)
        fixture.clock.fire(RevAILiveClient.sendFailureGrace)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [
            RevAIEventLog.urlError(.networkConnectionLost), .finished("Confirmed.")
        ])
    }

    func testFailedAudioSendDefersToTheClosureThatNamesItsCause() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        fixture.client.sendAudio(RevAILiveFixture.frame(2))
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertTrue(fixture.log.errors.isEmpty, "A broken socket does not say why it broke")
        fixture.client.sendAudio(RevAILiveFixture.frame(3))
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(1)], "Nothing more is sent after a failure")
        fixture.socket.closeByPeer(code: 4_003)
        XCTAssertEqual(fixture.log.entries, [.error("insufficientCredits")])
        fixture.clock.fire(RevAILiveClient.sendFailureGrace)
        XCTAssertEqual(fixture.log.errors.count, 1, "The grace of a settled run is inert")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testFailedSendCarryingThePeersCloseStatusIsReportedAtOnce() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        // WinHTTP hands the peer's closure to the pending send as well.
        fixture.socket.completeSend(CartesiaTestPeerClose(webSocketCloseCode: 4_029))
        XCTAssertEqual(fixture.log.entries, [.error("tooManyConnections")])
        XCTAssertEqual(fixture.clock.pending(RevAILiveClient.sendFailureGrace), 0)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testDocumentedStatusesMidStreamNameTheirCause() {
        let cases: [(code: Int, error: String)] = [
            (4_001, #"invalidAPIKey(provider: "Rev.ai")"#), (4_002, "badRequest"), (4_003, "insufficientCredits"),
            (4_013, "temporarilyUnavailable(closeCode: 4013)"), (4_029, "tooManyConnections"),
            (1_011, "closed(closeCode: 1011)")
        ]
        for (code, error) in cases {
            let fixture = RevAILiveFixture()
            fixture.startAndConnect()
            fixture.stream(RevAILiveFixture.frame(1))
            fixture.socket.closeByPeer(code: code)
            XCTAssertEqual(fixture.log.entries, [.error(error)], "\(code)")
            XCTAssertEqual(fixture.socket.cancels, 1, "\(code)")
        }
    }

    func testNormalClosureWithAPartialStillUnconfirmedIsReportedWithIt() async {
        let fixture = RevAILiveFixture()
        let finish = await finishingAfterEOS(fixture, confirmed: "Confirmed.")
        fixture.socket.revAIPartial(["cut", "off"])
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.", "Unconfirmed words are never returned as confirmed")
        XCTAssertEqual(Array(fixture.log.entries.suffix(3)), [
            .transcript("cut off", final: false), .error("incompleteSegment"), .finished("Confirmed.")
        ], "The withheld partial reaches the host before the error, and the error before the return")
    }

    func testPartialShownBeforeTheFinishAndNeverFinalisedIsReportedWithoutRepeatingIt() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIPartial(["shown"])
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [
            .transcript("shown", final: false), .error("incompleteSegment"), .finished(nil)
        ], "The host already shows the partial, so only the error follows it")
    }

    func testEmptyFinalClosesThePartialSoTheNormalClosureCompletes() async {
        let fixture = RevAILiveFixture()
        let finish = await finishingAfterEOS(fixture, confirmed: "Confirmed.")
        fixture.socket.revAIPartial(["um"])
        fixture.socket.revAIEmptyFinal()
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertTrue(fixture.log.errors.isEmpty, "A segment Rev.ai ended without words loses nothing")
    }

    func testStaleNormalClosureOfACancelledRunCompletesNothing() async {
        let fixture = RevAILiveFixture()
        let finish = await finishingAfterEOS(fixture, confirmed: "Confirmed.")
        fixture.socket.keepCallbacksAfterCancel()
        fixture.client.cancel()
        let transcript = await finish.value
        fixture.socket.revAIFinal("Late.")
        fixture.socket.closeNormally()
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.log.entries.last, .finished("Confirmed."))
        XCTAssertTrue(fixture.log.errors.isEmpty)
        XCTAssertFalse(fixture.log.entries.contains(.transcript("Late.", final: true)))
    }

    func testStaleNormalClosureCannotCompleteAReplacementFinish() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        let old = fixture.socket
        old.keepCallbacksAfterCancel()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.revAIConnected()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        replacement.completeSend()
        replacement.revAIFinal("Replacement.")
        let endOfStream = expectation(description: "Replacement EOS sent")
        replacement.onSend { message in
            if case .text(let text) = message, text == RevAILiveClient.endOfStreamToken { endOfStream.fulfill() }
        }
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        replacement.completeSend()
        old.closeNormally()
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "Only the replacement's own closure can complete it")
        replacement.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Replacement.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    /// Opens a session with one frame on the wire and one confirmed final, and
    /// finishes it up to the point where `EOS` has been delivered and the
    /// server's closure is due.
    private func finishingAfterEOS(_ fixture: RevAILiveFixture, confirmed: String) async -> Task<String?, Never> {
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal(confirmed)
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        return finish
    }
}
