import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A graceful finish: admitted audio drains, `audioStreamEnd` follows, and the
/// server's answer to it (the final of the utterance in flight, or the turn's
/// end) completes the stream inside one budget. Finals that arrive meanwhile
/// are returned in the whole transcript, never also delivered.
final class GeminiLiveFinishTests: XCTestCase {
    private typealias Fixture = GeminiLiveFixture

    func testFinishDrainsAudioThenEndsTheStreamAndReturnsTheWholeTranscript() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.client.sendAudio(Fixture.frame(2))
        fixture.socket.final("Hello there.")
        let streamEnd = fixture.expectStreamEnd(self)
        let finish = fixture.finish()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        await fulfillment(of: [streamEnd], timeout: 2)
        XCTAssertEqual(fixture.socket.kinds, ["setup", "audio", "audio", "streamEnd"])

        fixture.socket.completeSend()
        fixture.socket.interim("And good")
        fixture.socket.final("And goodbye.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello there. And goodbye.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Hello there.", final: true), .finished("Hello there. And goodbye.")
        ], "The answering final is returned once, not also delivered")
        XCTAssertEqual(fixture.socket.audio, [Fixture.frame(1), Fixture.frame(2)])
        XCTAssertEqual(fixture.socket.cancels, 1, "The client closes the session it no longer needs")
    }

    func testTurnCompleteAnswersTheStreamEndWhenNoUtteranceIsOpen() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Only this.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.turnComplete()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Only this.")
        XCTAssertEqual(fixture.log.entries.last, .finished("Only this."))
    }

    func testAnOpenUtteranceIsAwaitedPastTurnCompleteAndTheQuietPeriod() async {
        let fixture = Fixture()
        fixture.startReady()
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.interim("Still talk")
        fixture.socket.turnComplete()
        fixture.clock.fire(GeminiLiveClient.trailingSettle)
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "Unconfirmed words are still being transcribed")

        fixture.socket.final("Still talking.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Still talking.")
        XCTAssertEqual(fixture.log.entries, [.finished("Still talking.")])
    }

    /// The Live API sends nothing for a silent tail, so a short quiet period
    /// after `audioStreamEnd` is delivered ends the stream, without an error.
    func testSilentTailCompletesAfterTheQuietPeriod() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Said before stopping.")
        let finish = await fixture.finishUntilStreamEnd(self)
        XCTAssertEqual(fixture.clock.pending(GeminiLiveClient.trailingSettle), 0, "The period starts on delivery")
        fixture.socket.completeSend()
        fixture.clock.fire(GeminiLiveClient.trailingSettle)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Said before stopping.")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testAnswerThatArrivesBeforeTheStreamEndCompletesIsHonouredOnDelivery() async {
        let fixture = Fixture()
        fixture.startReady()
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.final("Tail.")
        XCTAssertEqual(fixture.client.pendingFinishes, 1, "Nothing completes before the end is delivered")
        fixture.socket.completeSend()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Tail.")
    }

    /// A final already on its way before `audioStreamEnd` is handed over did
    /// not answer it, so it is folded in and the answer is still awaited.
    func testFinalBeforeTheStreamEndIsHandedOverDoesNotCompleteTheFinish() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        let streamEnd = fixture.expectStreamEnd(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.final("Earlier.")
        XCTAssertEqual(fixture.socket.kinds, ["setup", "audio"])
        fixture.socket.completeSend()
        await fulfillment(of: [streamEnd], timeout: 2)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.client.pendingFinishes, 1)

        fixture.socket.final("Later.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Earlier. Later.")
        XCTAssertEqual(fixture.log.entries, [.finished("Earlier. Later.")])
    }

    func testFinishBudgetWithAnOpenUtteranceReportsItAfterDeliveringTheDraft() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Confirmed.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.interim("Unfinished")
        fixture.clock.fire(GeminiLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Confirmed.", final: true), .transcript("Unfinished", final: false),
            .error("incompleteUtterance"), .finished("Confirmed.")
        ])
    }

    func testFinishBudgetBeforeTheStreamEndIsDeliveredIsAStalledTransport() async {
        let fixture = Fixture()
        fixture.startReady()
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.clock.fire(GeminiLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [
            .error(#"transportStalled(provider: "Google Gemini")"#), .finished(nil)
        ])
    }

    func testFinishBeforeSetupCompleteWaitsForItThenFlushesTheHeldAudio() async {
        let fixture = Fixture()
        fixture.start()
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.client.sendAudio(Fixture.frame(7))
        let streamEnd = fixture.expectStreamEnd(self)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertEqual(fixture.socket.kinds, ["setup"])

        fixture.socket.setupComplete()
        fixture.socket.completeSend()
        await fulfillment(of: [streamEnd], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.final("Short.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Short.")
        XCTAssertEqual(fixture.socket.audio, [Fixture.frame(7)])
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testFinishWithoutSetupCompleteFailsAsNotReady() async {
        let fixture = Fixture()
        fixture.start()
        fixture.socket.open()
        let armed = expectation(description: "Readiness budget armed by the finish")
        let finish = fixture.finish()
        fixture.clock.armed(GeminiLiveClient.finishReadyBudget, armed)
        await fulfillment(of: [armed], timeout: 2)
        fixture.clock.fire(GeminiLiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady"), .finished(nil)])
    }

    func testConcurrentFinishCallersShareOneOutcome() async {
        let fixture = Fixture()
        fixture.startReady()
        let streamEnd = fixture.expectStreamEnd(self)
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishes(2)
        await fulfillment(of: [streamEnd], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.final("Shared.")
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Shared.", "Shared."])
        XCTAssertEqual(fixture.socket.kinds.filter { $0 == "streamEnd" }.count, 1)
    }

    func testFinishWithoutSpeechReturnsNil() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.interim("um")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.final("")
        let transcript = await finish.value
        XCTAssertNil(transcript, "An utterance that ends without words confirms nothing")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testFinishOfAClientThatNeverStartedReturnsAtOnce() async {
        let fixture = Fixture()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
    }

    func testANewRecordingStartsWithAnEmptyTranscript() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("First recording.")
        let first = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.turnComplete()
        _ = await first.value

        fixture.start()
        let socket = fixture.factory.sockets[1]
        socket.open()
        socket.completeSend()
        socket.setupComplete()
        socket.final("Second recording.")
        let streamEnd = fixture.expectStreamEnd(self, on: socket)
        let second = fixture.finish()
        await fulfillment(of: [streamEnd], timeout: 2)
        socket.completeSend()
        socket.turnComplete()
        let transcript = await second.value
        XCTAssertEqual(transcript, "Second recording.")
    }
}
