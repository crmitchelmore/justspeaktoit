import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Cancellation at every phase, run identity across restarts, and callbacks
/// that re-enter the client synchronously.
final class CartesiaLiveCancellationTests: XCTestCase {
    func testStopBeforeTheHandshakeCancelsAndIgnoresLateCallbacks() async {
        let fixture = CartesiaLiveFixture()
        fixture.start()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.client.stop()
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.open()
        fixture.socket.turn("Too late.")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(2))
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.log.entries.isEmpty, "Cancellation is not an error and delivers nothing")
    }

    func testCancelWithASendInFlightReleasesEverythingWithoutAnError() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.client.sendAudio(CartesiaLiveFixture.frame(2))
        fixture.client.cancel()
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.binary.count, 1, "Queued audio is released, not sent after cancellation")
        XCTAssertTrue(fixture.log.entries.isEmpty)
        fixture.clock.fireAll()
        XCTAssertTrue(fixture.log.entries.isEmpty, "Deadlines of a cancelled run do nothing")
    }

    func testCancelDuringFinishWakesEveryWaiterPromptly() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishes(2)
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.client.cancel()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Confirmed.", "Confirmed."])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testCancellingTheFinishingTaskAbortsTheSession() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.closeCommands, 0)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testAFinishTaskCancelledBeforeItStartsAbortsImmediately() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let client = fixture.client
        let finish = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.finishAndWait()
        }
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.client.pendingFinishes, 0)
        XCTAssertEqual(fixture.socket.closeCommands, 0)
    }

    func testRestartIsolatesTheOldRunFromItsLateCallbacksAndDeadlines() {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let old = fixture.socket
        old.keepCallbacksAfterCancel()
        for index in 0..<49 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        old.turnUpdate("Old draft")

        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        replacement.open()
        // Everything the old run still owns now arrives late.
        old.open()
        old.completeSend()
        old.turnEnd("Stale.")
        old.closeNormally()
        fixture.clock.fireAll()

        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(fixture.log.entries, [.transcript("Old draft", final: false)])
        // The replacement's own budget is intact: a full five seconds is admitted.
        for index in 0..<50 { fixture.client.sendAudio(CartesiaLiveFixture.frame(UInt8(index))) }
        replacement.turn("Fresh.")
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertEqual(old.binary.count, 1, "Nothing further left on the old socket")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [
            .transcript("Fresh.", final: false), .transcript("Fresh.", final: true)
        ])
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.cancel()
    }

    func testFailureIsPublishedBeforeWaitersResumeAndAReentrantStartSurvives() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let gate = DispatchSemaphore(value: 0)
        let released = CartesiaFlag()
        let entered = expectation(description: "Error callback entered")
        let returnedEarly = expectation(description: "Finish returned while the error was still being delivered")
        returnedEarly.isInverted = true
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            log.fail(error)
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            // A new session from inside the callback. The failed run's cleanup must not touch it.
            client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { log.fail($0) })
        })
        fixture.socket.open()
        fixture.socket.turn("Saved.")
        let closeSent = fixture.expectClose(self)
        let finish = Task { () -> String? in
            let transcript = await client.finishAndWait()
            if !released.isSet { returnedEarly.fulfill() }
            log.finished(transcript)
            return transcript
        }
        await fulfillment(of: [closeSent], timeout: 2)
        let old = fixture.socket
        DispatchQueue.global().async { old.serverError(status: 500) }
        await fulfillment(of: [entered], timeout: 2)
        await fulfillment(of: [returnedEarly], timeout: 0.2)
        released.set()
        gate.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Saved.")
        XCTAssertEqual(Array(log.entries.suffix(2)), [
            .error(#"server(statusCode: Optional(500), code: nil, message: "Synthetic failure")"#), .finished("Saved.")
        ])
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        client.sendAudio(CartesiaLiveFixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        client.cancel()
    }

    func testSynchronousErrorCallbackMayStartAReplacementImmediately() {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            log.fail(error)
            client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { log.fail($0) })
        })
        fixture.socket.open()
        // Odd PCM fails synchronously inside `sendAudio`, on this thread.
        client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(log.errors.first as? CartesiaStreamingError, .invalidPCM)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        client.sendAudio(CartesiaLiveFixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        client.cancel()
    }

    func testTranscriptCallbacksMayReenterTheClient() {
        let fixture = CartesiaLiveFixture()
        fixture.useSynchronousSends()
        let log = fixture.log, client = fixture.client
        client.start(onTranscript: { text, isFinal in
            log.transcript(text, final: isFinal)
            client.sendAudio(CartesiaLiveFixture.frame(9))
            if isFinal { client.stop() }
        }, onError: { log.fail($0) })
        fixture.socket.open()
        fixture.socket.turn("Stop here.")
        fixture.socket.turn("Ignored.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Stop here.", final: false), .transcript("Stop here.", final: true)
        ])
        XCTAssertEqual(fixture.socket.binary.count, 2, "Audio sent from inside each callback went out in order")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}
