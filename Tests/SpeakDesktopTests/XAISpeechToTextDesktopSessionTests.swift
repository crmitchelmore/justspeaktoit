import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The shared desktop session over the real xAI client and a fake transport:
/// what a Windows host sees while recording, on a silent session, at the end
/// and when the provider fails.
final class XAISpeechToTextDesktopSessionTests: XCTestCase {
    func testLiveTextFollowsInterimsAndLockedSpansThenTheWholeTranscriptReplacesIt() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        session.sendAudio(XAISpeechToTextLiveFixture.frame(1))
        XCTAssertEqual(socket.binary.count, 1)
        socket.transcriptPartial("Hel", isFinal: false)
        XCTAssertEqual(session.snapshot().text, "Hel")
        socket.transcriptPartial("Hello there.", isFinal: true, start: 0)
        socket.transcriptPartial("Hello there.", isFinal: true, start: 0)
        socket.transcriptPartial("Good", isFinal: false)
        XCTAssertEqual(session.snapshot().text, "Hello there. Good")
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await session.finish() }
        socket.completeSend()
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.transcriptDone("Hello there. Goodbye.")
        let result = await finish.value
        XCTAssertEqual(result.text, "Hello there. Goodbye.")
        XCTAssertEqual(result.phase, .finished)
        XCTAssertNil(result.error)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testSilentSessionFinishesEmptyWithoutInventingText() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        session.sendAudio(XAISpeechToTextLiveFixture.frame(0))
        socket.completeSend()
        socket.transcriptPartial("um", isFinal: false)
        XCTAssertEqual(session.snapshot().text, "um")
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await session.finish() }
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.transcriptDone("")
        let result = await finish.value
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.phase, .finished)
        XCTAssertNil(result.error)
    }

    func testProviderFailureReachesTheSessionAndRetainsTheBestText() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        fixture.socket.transcriptPartial("Kept.", isFinal: true, start: 0)
        fixture.socket.xaiError("Invalid API key")
        let failed = session.snapshot()
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.text, "Kept.")
        XCTAssertEqual(failed.error, StreamingClientError.invalidAPIKey(provider: "xAI").localizedDescription)
        XCTAssertEqual(fixture.socket.cancels, 1)
        let result = await session.finish()
        XCTAssertEqual(result, failed)
    }

    func testAdmissionFailureReachesTheSessionSynchronouslyWithoutDeadlock() {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        let completed = expectation(description: "Bounded admission failure is reported synchronously")
        DispatchQueue.global().async {
            session.start()
            session.sendAudio(XAISpeechToTextLiveFixture.frame(1, count: 240_002))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .failed)
        XCTAssertNotNil(session.snapshot().error)
        XCTAssertEqual(session.snapshot().text, "")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}
