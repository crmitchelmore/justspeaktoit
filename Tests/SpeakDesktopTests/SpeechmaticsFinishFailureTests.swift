import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// `EndOfTranscript` is the only successful end of a session. Every disconnect,
/// rejected send or expired deadline before it is a reported failure that keeps
/// the accumulated text; only an explicit cancel or a stale run stays silent.
final class SpeechmaticsFinishFailureTests: XCTestCase {
    /// The teardown-shaped closure the shared `WebSocketErrorFilter` treats as
    /// ignorable, which this client must still report while a run is current.
    private static let socketNotConnected = NSError(
        domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"]
    )

    // MARK: - Disconnects before the terminal frame

    func testReceiveFailureBeforeReadinessFailsTheSession() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.fail()
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(fixture.client.isSessionReady)
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertTrue(socket.binary.isEmpty, "A failed run accepts no further capture")
    }

    func testReceiveFailureWhileFinishingBeforeReadinessFailsWithoutText() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SpeechmaticsLiveClient.finishReadyBudget)
        socket.fail()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"))
        XCTAssertEqual(socket.cancels, 1)
    }

    func testReceiveFailureDuringTheAudioDrainFailsAndKeepsText() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.client.isFinishing }
        socket.completeSend()
        XCTAssertEqual(socket.binary.count, 2, "The drain is under way")
        socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.", "Already-final text survives alongside the error")
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"))
        XCTAssertEqual(socket.cancels, 1)
    }

    func testDisconnectAfterEndOfStreamBeforeEndOfTranscriptFailsAndKeepsText() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
    }

    // MARK: - Teardown-shaped errors are still failures

    func testTeardownShapedClosureOnAnActiveReceiveIsAFailure() {
        XCTAssertTrue(WebSocketErrorFilter.shouldIgnore(Self.socketNotConnected), "The shared filter would hide this")
        let socket = SpeechmaticsAutoSocket()
        let events = AssemblyAITestEvents()
        let client = SpeechmaticsLiveClient(
            apiKey: "synthetic", makeConnection: { _ in socket }, schedule: { _, _ in }
        )
        client.start(onTranscript: { _, _ in }, onError: { [events] in events.fail($0) })
        socket.recognitionStarted()
        XCTAssertTrue(client.isSessionReady)
        socket.failReceive(Self.socketNotConnected)
        XCTAssertEqual(events.errors.count, 1)
        XCTAssertFalse(client.isSessionReady)
        XCTAssertTrue(socket.isCancelled)
    }

    func testTeardownShapedSendFailureOnAudioIsAFailureNotASkippedFrame() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend(Self.socketNotConnected)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertEqual(fixture.client.audioFrameCount, 0, "A rejected frame is never counted as sent")
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"))
    }

    func testTeardownShapedSendFailureOnStartRecognitionIsAFailure() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        XCTAssertEqual(socket.messageNames, ["StartRecognition"])
        socket.completeSend(Self.socketNotConnected)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
        socket.recognitionStarted()
        XCTAssertFalse(fixture.client.isSessionReady, "A late RecognitionStarted cannot revive the failed run")
    }

    func testTeardownShapedSendFailureOnEndOfStreamFailsTheFinishAndKeepsText() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend(Self.socketNotConnected)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
    }

    // MARK: - Bounded deadlines

    func testReadinessTimeoutDuringAFinishReportsRecognitionNotStarted() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        socket.completeSend()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SpeechmaticsLiveClient.finishReadyBudget)
        fixture.clock.fire(SpeechmaticsLiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? SpeechmaticsRealtimeError, .recognitionNotStarted)
        XCTAssertTrue(socket.binary.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testDrainTimeoutDuringAFinishReportsATransportStall() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.client.isFinishing }
        fixture.clock.fire(SpeechmaticsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first as? StreamingClientError else {
            return XCTFail("Expected the stalled drain, got \(String(describing: fixture.events.errors.first))")
        }
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"))
        XCTAssertEqual(socket.cancels, 1)
    }

    func testTerminalTimeoutAfterEndOfStreamReportsTranscriptNotFinalised() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        fixture.clock.fire(SpeechmaticsLiveClient.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.events.errors.first as? SpeechmaticsRealtimeError, .transcriptNotFinalised)
        XCTAssertEqual(socket.cancels, 1)
    }

    // MARK: - Cancellation and stale runs stay silent

    func testCancellingTheFinishTaskClosesWithoutAnErrorAndKeepsText() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Retained.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Retained.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "Cancellation is not a provider or network error")
        XCTAssertEqual(socket.cancels, 1)
        socket.fail()
        socket.completeSend(URLError(.cancelled))
        XCTAssertTrue(fixture.events.errors.isEmpty, "Closure after our own cancel stays silent")
    }

    func testStaleFinishDeadlinesAndDisconnectCannotFailTheReplacementRun() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let old = fixture.socket
        old.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SpeechmaticsLiveClient.finishReadyBudget)
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertTrue(fixture.events.errors.isEmpty, "Restarting is the caller's decision, not a provider failure")
        let replacement = fixture.factory.sockets[1]
        oldDeadlines.forEach { $0() }
        old.fail()
        old.completeSend(URLError(.networkConnectionLost))
        old.endOfTranscript()
        XCTAssertTrue(fixture.events.errors.isEmpty)
        replacement.open()
        replacement.completeSend()
        replacement.recognitionStarted()
        replacement.addFinal("Current.")
        XCTAssertEqual(fixture.events.texts, ["Current."])
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(replacement.cancels, 0)
        fixture.client.cancel()
    }

    // MARK: - The desktop session sees the failure before finish returns

    func testDesktopSessionRecordsTheFailureBeforeFinishReturnsAndRetainsText() async {
        let fixture = SpeechmaticsLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        XCTAssertEqual(session.snapshot().text, "Kept.")
        let ending = expectation(description: "EndOfStream handed to the socket")
        socket.onSend = { if case .text(let text) = $0, text.contains("EndOfStream") { ending.fulfill() } }
        let finish = Task { await session.finish() }
        await fulfillment(of: [ending], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .finishing)
        socket.completeSend(URLError(.networkConnectionLost))
        let result = await finish.value
        XCTAssertEqual(result.phase, .failed)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.text, "Kept.")
        XCTAssertEqual(session.snapshot(), result)
        XCTAssertEqual(socket.cancels, 1)
    }
}
