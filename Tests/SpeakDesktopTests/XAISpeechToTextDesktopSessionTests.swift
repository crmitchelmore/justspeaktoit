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

    func testUnexpectedClosureAfterAudioDoneFailsTheSessionAndRetainsText() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Kept.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await session.finish() }
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        socket.fail()
        let result = await finish.value
        XCTAssertEqual(result.phase, .failed, "No transcript.done arrived, so the session is not complete")
        XCTAssertEqual(result.text, "Kept.", "Received text is kept for recovery")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testMissingCompletionAtTheFinishDeadlineFailsTheSessionAndRetainsText() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Kept.", isFinal: true, start: 0)
        let ending = expectation(description: "audio.done")
        socket.fulfillOnAudioDone(ending)
        let finish = Task { await session.finish() }
        await fulfillment(of: [ending], timeout: 2)
        socket.completeSend()
        await fixture.waitForScheduled(XAISpeechToTextLiveClient.finishBudget, count: 2)
        fixture.clock.fire(XAISpeechToTextLiveClient.finishBudget)
        let result = await finish.value
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.text, "Kept.")
        XCTAssertEqual(result.error, XAISpeechToTextError.missingCompletion.localizedDescription)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testClosureAfterTranscriptDoneKeepsTheFinishedResult() async {
        let fixture = XAISpeechToTextLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.transcriptPartial("Whole", isFinal: false)
        socket.transcriptDone("Whole thing.")
        XCTAssertEqual(session.snapshot().text, "Whole thing.")
        socket.fail()
        XCTAssertEqual(session.snapshot().phase, .recording, "A closure after transcript.done is the normal end")
        let result = await session.finish()
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.text, "Whole thing.")
        XCTAssertNil(result.error)
    }

    func testDesktopFactoryForwardsTheLanguageSelectionToTheDedicatedStream() throws {
        let factory = AssemblyAISocketFactory()
        let selections: [String?] = ["en_GB", "pt-BR", "Automatic", "cy_GB", nil]
        for selection in selections {
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: XAISpeechToText.liveCatalogID, apiKey: "synthetic", language: selection,
                makeConnection: { factory.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Unexpected error") })
            client.cancel()
        }
        // The established call site keeps compiling and sends no language.
        let legacy = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: XAISpeechToText.liveCatalogID, apiKey: "synthetic", makeConnection: { factory.make($0) }
        ))
        legacy.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Unexpected error") })
        legacy.cancel()
        let languages = try factory.requests.map { request -> String? in
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            return components.queryItems?.first { $0.name == "language" }?.value
        }
        XCTAssertEqual(languages, ["en", "pt", nil, nil, nil, nil], "Only documented codes travel, never a raw locale")
        XCTAssertTrue(factory.requests.allSatisfy {
            $0.url?.query?.contains("model=grok-voice-transcribe-2.0") == true
        })
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
