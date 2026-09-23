import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Restart identity, typed error reporting, failure/finish ordering and the
/// bounded PCM admission budget, all driven through the injected transport.
final class SpeechmaticsFailureTests: XCTestCase {

    // MARK: - Restart identity

    func testOldOpenReceiveSendAndDeadlinesCannotMutateTheReplacement() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let old = fixture.socket
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1, "Starting again cancels the prior run")
        old.open()
        old.recognitionStarted()
        old.completeSend(URLError(.networkConnectionLost))
        old.addFinal("Stale.")
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty, "A late old callback cannot fail the replacement")
        XCTAssertTrue(fixture.events.texts.isEmpty, "A late old callback cannot deliver into the replacement")
        XCTAssertFalse(fixture.client.isSessionReady)

        replacement.open()
        replacement.completeSend()
        replacement.recognitionStarted()
        replacement.addFinal("Current.")
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertEqual(fixture.events.texts, ["Current."])
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testCancellingAnOldFinishCannotCloseTheReplacement() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        old.completeSend()
        let ending = expectation(description: "Finish reached EndOfStream")
        old.onSend = { if case .text(let text) = $0, text.contains("EndOfStream") { ending.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [ending], timeout: 2)
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        finish.cancel()
        _ = await finish.value
        replacement.open()
        replacement.completeSend()
        replacement.recognitionStarted()
        fixture.client.sendAudio(Data(repeating: 0, count: 3_200))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testReentrantImmediateTransportCompletionAndCancelDoNotDeadlock() {
        for _ in 0..<30 {
            let socket = SpeechmaticsAutoSocket()
            let events = AssemblyAITestEvents()
            let client = SpeechmaticsLiveClient(apiKey: "synthetic", makeConnection: { _ in socket })
            client.start(onTranscript: { _, _ in }, onError: { [events] in events.fail($0) })
            socket.recognitionStarted()
            client.sendAudio(Data(repeating: 1, count: 3_200))
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0: client.sendAudio(Data(repeating: 2, count: 3_200))
                case 1: socket.recognitionStarted()
                default: client.cancel()
                }
            }
            XCTAssertLessThanOrEqual(events.errors.count, 1)
            XCTAssertTrue(socket.isCancelled)
        }
    }

    // MARK: - Typed errors and ordering

    func testTypedProviderErrorsAreClassifiedAndReported() {
        let auth = SpeechmaticsLiveFixture()
        auth.start(); auth.becomeReady()
        auth.socket.speechmaticsError(type: "not_authorised", reason: "Not authorised")
        XCTAssertEqual(auth.events.errors.first as? SpeechmaticsRealtimeError, .unauthorized)
        XCTAssertEqual(auth.socket.cancels, 1)

        let quota = SpeechmaticsLiveFixture()
        quota.start(); quota.becomeReady()
        quota.socket.speechmaticsError(type: "quota_exceeded", reason: "No hours")
        XCTAssertEqual(quota.events.errors.first as? SpeechmaticsRealtimeError, .quotaExceeded(message: "No hours"))

        let server = SpeechmaticsLiveFixture()
        server.start(); server.becomeReady()
        server.socket.speechmaticsError(type: "job_error", reason: "Internal")
        XCTAssertEqual(server.events.errors.first as? SpeechmaticsRealtimeError, .server(message: "Internal"))
    }

    func testReadinessErrorFrameIsReportedDuringAFinish() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SpeechmaticsLiveClient.finishReadyBudget)
        socket.speechmaticsError(type: "not_authorised", reason: "Bad key")
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? SpeechmaticsRealtimeError, .unauthorized)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testAudioSendFailureIsReportedAndNotSilentlyFinalised() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Best available.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.binary.count == 1 }
        socket.completeSend(URLError(.networkConnectionLost))
        let transcript = await finish.value
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"), "No EndOfStream after a failed audio send")
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(transcript, "Best available.", "Already-final text is returned alongside the error")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testKnownClosureAfterIntentionalCancelIsSuppressed() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.cancel()
        fixture.socket.fail()
        XCTAssertTrue(fixture.events.errors.isEmpty, "A closure after an intentional cancel is not surfaced")
    }

    func testFailureIsPublishedBeforeFinishReturnsAndMayStartAReplacement() async {
        let fixture = SpeechmaticsLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered on the provider queue")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = SpeechmaticsFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        fixture.becomeReady()
        let old = fixture.socket
        old.addFinal("Saved.")
        client.sendAudio(Data(repeating: 0, count: 3_200))
        let ending = expectation(description: "EndOfStream proves the finish waiter is registered")
        old.onSend = { if case .text(let text) = $0, text.contains("EndOfStream") { ending.fulfill() } }
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        old.completeSend()
        await fulfillment(of: [ending], timeout: 2)
        DispatchQueue.global().async { old.completeSend(URLError(.networkConnectionLost)) }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.recognitionStarted()
        client.sendAudio(Data(repeating: 0, count: 3_200))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        client.cancel()
    }

    // MARK: - Bounded PCM admission

    func testByteBudgetOverflowBeforeRecognitionReportsOnceAndReleases() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = fixture.events.errors.first as? StreamingClientError else {
            return XCTFail("Expected a transport-stalled overflow error")
        }
        XCTAssertEqual(socket.cancels, 1, "The run is cancelled and the admitted data released")
    }

    func testOversizedChunkIsRejectedBeforeAnyQueueGrowth() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 160_002))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertTrue(socket.binary.isEmpty, "Rejected before any frame is queued or sent")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testStalledSendReportsOneErrorAndCancels() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.clock.fire(SpeechmaticsLiveClient.sendDeadline)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testStaleSendCompletionCannotReleaseTheReplacementRunsBudget() {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.recognitionStarted()
        fixture.client.sendAudio(Data(repeating: 2, count: 160_000))
        old.completeSend()
        fixture.client.sendAudio(Data(repeating: 3, count: 3_200))
        XCTAssertEqual(fixture.events.errors.count, 1, "The stale completion did not free the replacement budget")
        XCTAssertEqual(replacement.cancels, 1)
        XCTAssertEqual(old.cancels, 1)
    }
}

/// Opens and completes every send synchronously, so the client's reentrant
/// completion path runs under concurrency, exactly as an immediate native
/// adapter would.
final class SpeechmaticsAutoSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        completion(nil)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func recognitionStarted() {
        let callback = lock.withLock { let value = receiver; receiver = nil; return value }
        callback?(.success(.text(#"{"message":"RecognitionStarted","id":"sess_1"}"#)))
    }
    func failReceive(_ error: Error) {
        let callback = lock.withLock { let value = receiver; receiver = nil; return value }
        callback?(.failure(error))
    }
}

private final class SpeechmaticsFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
