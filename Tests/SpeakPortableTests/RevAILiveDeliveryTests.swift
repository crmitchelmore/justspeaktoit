import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Work the client decides under its lock runs later, outside it. A failure is
/// never reported ahead of a transcript the host is already being given, every
/// finish caller returns only after the error, cancellation is not an error,
/// and a stopped or replaced run can no longer reach a socket or the host.
final class RevAILiveDeliveryTests: XCTestCase {
    // MARK: Failure reports

    func testFailureReportFollowsAFinalAlreadyBeingDelivered() async {
        let fixture = RevAILiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "A final is being delivered to the host")
        client.start(onTranscript: { text, isFinal in
            if isFinal {
                delivering.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            log.transcript(text, final: isFinal)
        }, onError: { log.fail($0) })
        let socket = fixture.socket
        socket.revAIConnected()
        DispatchQueue.global().async { socket.revAIFinal("Final words.") }
        await fulfillment(of: [delivering], timeout: 2)

        let returned = expectation(description: "The capture call returned without waiting for the host")
        DispatchQueue.global().async {
            client.sendAudio(Data([1, 2, 3]))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(socket.cancels, 1, "The failed run is retired at once")
        XCTAssertTrue(log.errors.isEmpty, "Its report waits behind the final already on its way to the host")

        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        release.signal()
        let transcript = await late.value
        XCTAssertEqual(transcript, "Final words.")
        XCTAssertEqual(log.entries, [
            .transcript("Final words.", final: true), .error("invalidPCM"), .finished("Final words.")
        ])
    }

    func testRegisteredAndLateFinishesBothReturnAfterTheErrorCallback() async {
        let fixture = RevAILiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "Error callback entered")
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            delivering.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.fail(error)
        })
        fixture.socket.revAIConnected()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let endOfStream = fixture.expectEndOfStream(self)
        let registered = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.socket.completeSend()
        let socket = fixture.socket
        DispatchQueue.global().async { socket.closeByPeer(code: 4_003) }
        await fulfillment(of: [delivering], timeout: 2)

        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertFalse(log.entries.contains(.finished("Confirmed.")))
        release.signal()

        let results = await [registered.value, late.value]
        XCTAssertEqual(results, ["Confirmed.", "Confirmed."])
        XCTAssertEqual(Array(log.entries.suffix(3)), [
            .error("insufficientCredits"), .finished("Confirmed."), .finished("Confirmed.")
        ], "Both callers return after the error, never before it")
    }

    func testFinishJoiningWhileTheFailedSocketIsCancelledReturnsOnlyAfterTheError() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let cancelling = expectation(description: "The failure retired the run and is cancelling its socket")
        fixture.socket.holdCancel(until: release) { cancelling.fulfill() }
        let socket = fixture.socket
        DispatchQueue.global().async { socket.closeByPeer(code: 4_003) }
        await fulfillment(of: [cancelling], timeout: 2)
        XCTAssertTrue(fixture.log.errors.isEmpty, "The run is terminal but its error is not delivered yet")

        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertFalse(fixture.log.entries.contains(.finished("Confirmed.")), "The late finish must wait")
        release.signal()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [.error("insufficientCredits"), .finished("Confirmed.")])
        XCTAssertEqual(fixture.client.pendingFinishes, 0)
    }

    func testErrorCallbackMayStartAReplacementTheFailedRunNeverTouches() async {
        let fixture = RevAILiveFixture()
        let log = fixture.log, client = fixture.client
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            log.fail(error)
            client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { log.fail($0) })
        })
        let old = fixture.socket
        old.keepCallbacksAfterCancel()
        old.revAIConnected()
        fixture.stream(RevAILiveFixture.frame(1))
        old.revAIFinal("Old.")
        let endOfStream = fixture.expectEndOfStream(self)
        let finish = fixture.finish()
        await fulfillment(of: [endOfStream], timeout: 2)
        old.completeSend()
        old.closeByPeer(code: 4_003)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Old.")
        guard fixture.factory.sockets.count == 2 else { return XCTFail("The replacement was never started") }

        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(replacement.cancels, 0, "The old run's cleanup cannot touch the replacement")
        replacement.revAIConnected()
        old.revAIFinal("Stale.")
        fixture.clock.fireAll()
        client.sendAudio(RevAILiveFixture.frame(2))
        replacement.revAIFinal("New.")
        XCTAssertEqual(replacement.binary, [RevAILiveFixture.frame(2)])
        XCTAssertEqual(log.entries, [
            .transcript("Old.", final: true), .error("insufficientCredits"), .finished("Old."),
            .transcript("New.", final: true)
        ])
        XCTAssertEqual(replacement.cancels, 0)
        client.cancel()
    }

    // MARK: Cancellation

    func testAudioClaimedBeforeCancellationIsNeverHandedToTheCancelledSocket() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        let client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Frame claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: RevAILiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let returned = expectation(description: "The capture call returned")
        DispatchQueue.global().async {
            client.sendAudio(RevAILiveFixture.frame(1))
            returned.fulfill()
        }
        await fulfillment(of: [claimed], timeout: 2)
        client.cancel()
        XCTAssertEqual(fixture.socket.cancels, 1)
        release.signal()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertTrue(fixture.socket.sent.isEmpty, "A claimed frame never reaches the cancelled socket")
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testCancelDuringFinishWakesEveryWaiterWithConfirmedTextAndNoError() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.stream(RevAILiveFixture.frame(1))
        fixture.socket.revAIFinal("Confirmed.")
        fixture.socket.revAIPartial(["not", "confirmed"])
        let endOfStream = fixture.expectEndOfStream(self)
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishes(2)
        await fulfillment(of: [endOfStream], timeout: 2)
        fixture.client.cancel()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Confirmed.", "Confirmed."], "A cancelled finish returns confirmed words only")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.log.errors.isEmpty, "Cancellation is not a provider failure")
    }

    func testCancellingTheFinishingTaskAbortsTheSessionWithoutAnError() async {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        fixture.socket.revAIFinal("Confirmed.")
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.endOfStreamFrames, 0)
        XCTAssertTrue(fixture.log.errors.isEmpty)

        let restarted = RevAILiveFixture()
        restarted.startAndConnect()
        restarted.stream(RevAILiveFixture.frame(1))
        let client = restarted.client
        let cancelledFirst = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.finishAndWait()
        }
        let aborted = await cancelledFirst.value
        XCTAssertNil(aborted)
        XCTAssertEqual(restarted.socket.cancels, 1, "A finish cancelled before it starts aborts at once")
        XCTAssertEqual(restarted.client.pendingFinishes, 0)
        XCTAssertEqual(restarted.socket.endOfStreamFrames, 0)
    }

    func testCancellationWhileTheConnectionIsBuiltNeverOpensOrReconnects() async {
        let fixture = RevAILiveFixture()
        let client = fixture.client
        fixture.factory.configure { _ in client.cancel() }
        fixture.start()
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.resumes, 0, "A run cancelled during construction never resumes its socket")
        XCTAssertFalse(fixture.socket.isReceiving)

        client.sendAudio(RevAILiveFixture.frame(1))
        let transcript = await client.finishAndWait()
        fixture.clock.fireAll()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.factory.sockets.count, 1, "Nothing reconnects after cancellation")
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        XCTAssertTrue(fixture.log.entries.isEmpty, "Cancellation is not an error")
    }

    // MARK: Run identity and re-entrancy

    func testRestartIsolatesTheOldRunFromItsLateCallbacksAndDeadlines() {
        let fixture = RevAILiveFixture()
        fixture.startAndConnect()
        let old = fixture.socket
        old.keepCallbacksAfterCancel()
        for index in 0..<49 { fixture.client.sendAudio(RevAILiveFixture.frame(UInt8(index))) }
        old.revAIPartial(["old", "draft"])

        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        replacement.revAIConnected()
        // Everything the old run still owns now arrives late.
        old.completeSend()
        old.revAIFinal("Stale.")
        old.closeByPeer(code: 4_003)
        fixture.clock.fireAll()

        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(fixture.log.entries, [.transcript("old draft", final: false)])
        // The replacement's own budget is intact: a full five seconds is admitted.
        for index in 0..<50 { fixture.client.sendAudio(RevAILiveFixture.frame(UInt8(index))) }
        replacement.revAIFinal("Fresh.")
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertEqual(old.binary.count, 1, "Nothing further left on the old socket")
        XCTAssertEqual(fixture.log.entries.last, .transcript("Fresh.", final: true))
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.cancel()
    }

    func testTranscriptCallbacksMayReenterTheClient() {
        let fixture = RevAILiveFixture()
        fixture.useSynchronousSends()
        let log = fixture.log, client = fixture.client
        client.start(onTranscript: { text, isFinal in
            log.transcript(text, final: isFinal)
            client.sendAudio(RevAILiveFixture.frame(9))
            if isFinal { client.stop() }
        }, onError: { log.fail($0) })
        fixture.socket.revAIConnected()
        fixture.socket.revAIPartial(["stop"])
        fixture.socket.revAIFinal("Stop here.")
        fixture.socket.revAIFinal("Ignored.")
        XCTAssertEqual(log.entries, [.transcript("stop", final: false), .transcript("Stop here.", final: true)])
        XCTAssertEqual(fixture.socket.binary.count, 2, "Audio sent from inside each callback went out in order")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}
