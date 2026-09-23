import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The shared desktop session over the shared Gemini client: the server's
/// answer to `audioStreamEnd` is the only success, every failure keeps the best
/// visible text for recovery, and a failure can never be overtaken by a
/// finish reporting success.
final class GeminiDesktopSessionTests: XCTestCase {
    func testSessionFinishesWithTheWholeTranscriptOnceTheStreamEndIsAnswered() async {
        let fixture = SessionFixture()
        fixture.ready()
        fixture.session.sendAudio(GeminiLiveFixture.frame(1))
        fixture.socket.completeSend()
        fixture.socket.final("First utterance.")
        XCTAssertEqual(fixture.session.snapshot().text, "First utterance.")

        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.interim("Second")
        fixture.socket.final("Second utterance.")
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "First utterance. Second utterance.")
        XCTAssertNil(snapshot.error)
    }

    func testDroppedConnectionDuringTheFinishFailsAndKeepsEveryWord() async {
        let fixture = SessionFixture()
        fixture.ready()
        fixture.socket.final("Confirmed.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.interim("Trailing words")
        fixture.socket.closeByPeer()
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed, "A dropped connection is never a completed transcript")
        XCTAssertEqual(snapshot.text, "Confirmed. Trailing words", "The withheld draft stays visible for recovery")
        XCTAssertEqual(snapshot.error, GeminiLiveStreamingError.incompleteUtterance.localizedDescription)
    }

    func testDroppedConnectionAfterTheFlushWasAnsweredStillFinishes() async {
        let fixture = SessionFixture()
        fixture.ready()
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.final("Answered.")
        fixture.socket.closeByPeer()
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .finished, "The answer completed the stream before the socket closed")
        XCTAssertEqual(snapshot.text, "Answered.")
    }

    func testUnconfirmedUtteranceAtTheFinishBudgetFailsWithItsDraftKept() async {
        let fixture = SessionFixture()
        fixture.ready()
        fixture.socket.final("Confirmed.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.completeSend()
        fixture.socket.interim("Never finalised")
        fixture.clock.fire(GeminiLiveClient.finishBudget)
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Confirmed. Never finalised")
        XCTAssertEqual(snapshot.error, GeminiLiveStreamingError.incompleteUtterance.localizedDescription)
    }

    func testServerErrorWhileRecordingFailsTheSessionAndAFinishKeepsTheText() async {
        let fixture = SessionFixture()
        fixture.ready()
        fixture.socket.final("Before the error.")
        fixture.socket.serverError(code: 429, status: "RESOURCE_EXHAUSTED")
        XCTAssertEqual(fixture.session.snapshot().phase, .failed)
        let snapshot = await fixture.session.finish()
        XCTAssertEqual(snapshot.phase, .failed, "The failed session is never reported as finished")
        XCTAssertEqual(snapshot.text, "Before the error.")
        XCTAssertEqual(snapshot.error, GeminiLiveError.rateLimited("Synthetic failure").localizedDescription)
    }

    func testCancellingTheSessionDuringTheFinishIsNotAFailure() async {
        let fixture = SessionFixture()
        fixture.ready()
        fixture.socket.final("Kept.")
        let finish = await fixture.finishUntilStreamEnd(self)
        let cancelled = fixture.session.cancel()
        XCTAssertEqual(cancelled.phase, .cancelled)
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertEqual(snapshot.text, "Kept.")
        XCTAssertNil(snapshot.error)
    }
}

/// One desktop session over a Gemini client whose transport and deadlines the
/// test drives.
private final class SessionFixture: @unchecked Sendable {
    let factory = GeminiSocketFactory()
    let clock = GeminiTestClock()
    let client: GeminiLiveClient
    let session: DesktopLiveSession

    init() {
        let factory = factory, clock = clock
        client = GeminiLiveClient(
            apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        session = DesktopLiveSession(client: client)
        session.start()
    }

    var socket: GeminiTestSocket { factory.sockets[0] }

    func ready() {
        socket.open()
        socket.completeSend()
        socket.setupComplete()
    }

    func finishUntilStreamEnd(_ test: XCTestCase) async -> Task<DesktopLiveSession.Snapshot, Never> {
        let sent = test.expectation(description: "audioStreamEnd handed to the transport")
        socket.onSend { if GeminiSentFrame($0) == .streamEnd { sent.fulfill() } }
        let session = session
        let finish = Task { await session.finish() }
        await test.fulfillment(of: [sent], timeout: 2)
        return finish
    }
}
