import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Graceful finalisation: drain, the literal `EOS`, then the trailing final and
/// the server's normal closure, inside one bounded budget, with every failure
/// published before the finish returns its confirmed text.
final class RevAILiveFinishTests: XCTestCase {
    /// Every deadline the run arms is named by when it was armed, because a
    /// send deadline and the whole-finish budget have the same length.
    func testFinishDrainsEveryFrameThenSendsEOSAndCompletesOnTheNormalClosure() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        let frames = (1...3).map { RevAILiveFixture.frame(UInt8($0)) }
        frames.forEach(fixture.client.sendAudio)
        fixture.socket.revAIFinal("Before stop.")
        XCTAssertEqual(fixture.deadlines.armed, [RevAILiveClient.readyDeadline, RevAILiveClient.sendDeadline],
                       "Readiness at start, then the send deadline of the one frame in flight")
        let budget = fixture.deadlines.armed.count
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForDeadlines(budget + 1)
        XCTAssertEqual(fixture.deadlines.armed.count, budget + 1, "With a frame in flight the finish arms only its own")
        XCTAssertEqual(fixture.deadlines.armed.dropFirst(budget).first, RevAIStreaming.finishBudget)
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0, "EOS waits for every admitted frame")
        for _ in frames {
            let armed = fixture.deadlines.armed.count
            fixture.socket.completeSend()
            XCTAssertEqual(fixture.deadlines.armed.count, armed + 1, "The next frame, then EOS, arms its send deadline")
        }
        await fulfillment(of: [endOfStream], timeout: 2)
        let expected = frames.map { StreamingWebSocketMessage.binary($0) } + [.text("EOS")]
        XCTAssertEqual(fixture.socket.sent, expected)
        fixture.client.sendAudio(RevAILiveFixture.frame(9))
        XCTAssertEqual(fixture.socket.binary, frames, "Audio offered after the finish began is not sent")
        fixture.socket.completeSend()
        fixture.socket.revAIPartial(["after"])
        fixture.socket.revAIFinal("After stop.")
        fixture.socket.closeNormally()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Before stop. After stop.")
        let entries: [RevAIEventLog.Entry] = [
            .transcript("Before stop.", final: true), .finished("Before stop. After stop.")
        ]
        XCTAssertEqual(fixture.log.entries, entries, "Hypotheses during the finish are returned once, not delivered")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.deadlines.armed.count, 6, "Readiness, a send deadline per frame and EOS, the budget")
        XCTAssertTrue(fixture.deadlines.fired.isEmpty, "The normal closure, not a deadline, completed the finish")

        // Every deadline of the completed run now comes due, late; none may act.
        fixture.clock.fireAll()
        XCTAssertEqual(fixture.deadlines.fired, Array(0..<6))
        XCTAssertEqual(fixture.log.entries, entries, "No late error or transcript")
        XCTAssertEqual(fixture.socket.sent, expected, "Nothing more is sent")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testFinishWithoutAnyAudioClosesAtOnceWithoutEOS() async {
        for connected in [true, false] {
            let fixture = RevAILiveFixture()
            if connected { fixture.startAndConnect() } else { fixture.start() }
            let transcript = await fixture.client.finishAndWait()
            XCTAssertNil(transcript)
            XCTAssertEqual(fixture.socket.endOfStreamFrames, 0, "Nothing was recorded, so nothing is flushed")
            XCTAssertEqual(fixture.socket.cancels, 1)
            XCTAssertTrue(fixture.log.entries.isEmpty)
            XCTAssertEqual(fixture.deadlines.armed, [RevAILiveClient.readyDeadline],
                           "The finish arms no deadline of its own")
        }
    }

    func testSilenceCompletesWithNoTranscriptAndNoError() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        (0..<5).forEach { _ in fixture.stream(RevAILiveFixture.frame(0)) }
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.revAIEmptyFinal()
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [.finished(nil)])
    }

    func testFinishBeforeStartReturnsNilAndNeverConnects() async {
        let fixture = RevAILiveFixture()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.startAndConnect()
        defer { fixture.client.cancel() }
        XCTAssertTrue(fixture.socket.sent.isEmpty, "Audio from before a finished idle client is not replayed")
    }

    func testFinishBeforeConnectedSendsTheHeldCaptureOnceItArrives() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        let frames = [RevAILiveFixture.frame(1), RevAILiveFixture.frame(2)]
        frames.forEach(fixture.client.sendAudio)
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertEqual(fixture.clock.pending(RevAILiveClient.finishReadyBudget), 1)
        fixture.socket.open()
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        fixture.socket.revAIConnected()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        await fulfillment(of: [endOfStream], timeout: 2)
        XCTAssertEqual(fixture.socket.binary, frames)
        fixture.socket.completeSend()
        fixture.socket.revAIFinal("Held words.")
        fixture.socket.closeNormally()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Held words.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testFinishBeforeAConnectedThatNeverArrivesFailsVisibly() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.socket.open()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.clock.fire(RevAILiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady"), .finished(nil)])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.socket.sent.isEmpty)
    }

    func testConcurrentAndRepeatedFinishesShareOneEOSAndOneOutcome() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Shared.")
        let endOfStream = fixture.expectEndOfStream(self)
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishes(2)
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.closeNormally()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Shared.", "Shared."])
        let repeated = await fixture.client.finishAndWait()
        XCTAssertEqual(repeated, "Shared.", "A later finish returns the same outcome")
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 1, "Nothing reconnects")
    }

    func testClosureWhileEOSIsInFlightIsSettledByItsCompletion() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.revAIFinal("Flushed.")
        fixture.socket.closeNormally()
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "EOS's own completion decides")
        fixture.socket.completeSend()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Flushed.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testFinishBudgetAfterADeliveredEOSReportsAMissingCompletion() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let budget = fixture.deadlines.armed.count
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        // The finish armed its budget, then claimed EOS, which armed its own send deadline.
        XCTAssertEqual(fixture.deadlines.armed.count, budget + 2)
        XCTAssertEqual(fixture.deadlines.armed.dropFirst(budget).first, RevAIStreaming.finishBudget)
        fixture.fireEndingTheFinish(budget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("missingCompletion"), .finished("Confirmed.")])
        XCTAssertEqual(fixture.deadlines.fired, [budget], "Only the whole-finish budget ran")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testDrainThatNeverCompletesReportsAStalledTransport() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        let budget = fixture.deadlines.armed.count
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        await fixture.waitForDeadlines(budget + 1)
        XCTAssertEqual(fixture.deadlines.armed.dropFirst(budget).first, RevAIStreaming.finishBudget)
        fixture.fireEndingTheFinish(budget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [RevAIEventLog.stalled, .finished(nil)])
        XCTAssertEqual(fixture.deadlines.fired, [budget], "The finish budget, not the frame's send deadline, ended it")
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0, "EOS never overtakes an admitted frame")
    }

    func testFailureDuringTheFinishReleasesWithheldWordsBeforeTheError() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Early.")
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.revAIFinal("Kept.")
        fixture.socket.revAIPartial(["still", "open"])
        fixture.socket.closeByPeer(code: 4_003)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Early. Kept.", "Only confirmed words are returned")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Early.", final: true), .transcript("Kept.", final: true),
            .transcript("still open", final: false), .error("insufficientCredits"), .finished("Early. Kept.")
        ], "Withheld words reach the host before the error, and the error before the return")
    }
}
