import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// `goAway` announces the documented ten-minute session limit. The ending
/// session's utterance is flushed and answered first; audio captured meanwhile
/// waits, then continues, in order, on a new session with the same request.
final class GeminiLiveHandoverTests: XCTestCase {
    private typealias Fixture = GeminiLiveFixture

    func testGoAwayFlushesTheSessionThenContinuesInOrderOnANewOne() {
        let fixture = Fixture()
        fixture.startReady()
        let first = fixture.socket
        fixture.client.sendAudio(Fixture.frame(1))
        first.completeSend()
        first.interim("Before the")
        first.goAway()
        XCTAssertEqual(first.kinds, ["setup", "audio", "streamEnd"], "The ending session takes no more audio")

        fixture.client.sendAudio(Fixture.frame(2))
        first.completeSend()
        XCTAssertEqual(fixture.factory.sockets.count, 1, "The flush is answered before a new session opens")
        first.final("Before the limit.")
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(first.cancels, 1)
        XCTAssertEqual(fixture.factory.requests[1], fixture.factory.requests[0])

        let second = fixture.factory.sockets[1]
        fixture.client.sendAudio(Fixture.frame(3))
        second.open()
        second.completeSend()
        XCTAssertEqual(second.kinds, ["setup"])
        XCTAssertEqual(second.texts.first, first.texts.first, "The new session repeats the same setup")
        second.setupComplete()
        second.completeSend()
        second.completeSend()
        XCTAssertEqual(second.audio, [Fixture.frame(2), Fixture.frame(3)])
        second.final("After it.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Before the", final: false), .transcript("Before the limit.", final: true),
            .transcript("After it.", final: true)
        ])
    }

    func testSilentFlushHandsOverAfterTheQuietPeriod() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.socket.completeSend()
        fixture.socket.goAway()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        fixture.clock.fire(GeminiLiveClient.trailingSettle)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    /// The ending session may close before answering once its end of audio
    /// was delivered with nothing in flight: the recording continues.
    func testEndingSessionThatClosesAfterItsFlushStillHandsOver() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.socket.completeSend()
        fixture.socket.goAway()
        fixture.socket.completeSend()
        fixture.socket.closeByPeer(code: 1_000)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testEndingSessionThatClosesWithWordsInFlightFailsWithTheirDraft() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.socket.completeSend()
        fixture.socket.interim("Cut off")
        fixture.socket.goAway()
        fixture.socket.completeSend()
        fixture.socket.closeByPeer(code: 1_011)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.log.entries, [.transcript("Cut off", final: false), .error("incompleteUtterance")])
    }

    /// A server that ends the replacement before it has accepted any audio
    /// ends the run: a handover can never become a reconnect storm.
    func testSecondGoAwayBeforeTheReplacementAcceptsAudioEndsTheRun() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.goAway()
        fixture.socket.completeSend()
        fixture.socket.turnComplete()
        let second = fixture.factory.sockets[1]
        second.open()
        second.completeSend()
        second.setupComplete()
        second.goAway()
        XCTAssertEqual(fixture.log.entries, [.error("sessionEnded")])
        XCTAssertEqual(fixture.factory.sockets.count, 2)
    }

    func testGoAwayDuringAFinishWithNothingLeftCompletesOnTheEndingSession() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Everything.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.goAway()
        fixture.socket.completeSend()
        fixture.socket.turnComplete()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Everything.")
        XCTAssertEqual(fixture.factory.sockets.count, 1, "Nothing was left for a new session")
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testReplacementThatNeverAnswersItsSetupFailsAtItsOwnDeadline() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.clock.fire(GeminiLiveClient.readyDeadline)
        fixture.client.sendAudio(Fixture.frame(1))
        fixture.socket.completeSend()
        fixture.socket.goAway()
        fixture.socket.completeSend()
        fixture.socket.turnComplete()
        let second = fixture.factory.sockets[1]
        second.open()
        second.completeSend()
        XCTAssertTrue(fixture.log.entries.isEmpty, "The first session's deadline was spent and cannot fire again")
        fixture.clock.fire(GeminiLiveClient.readyDeadline)
        XCTAssertEqual(fixture.log.entries, [.error("sessionNotReady")])
    }
}
