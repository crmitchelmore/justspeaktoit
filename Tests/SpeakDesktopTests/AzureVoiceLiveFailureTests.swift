import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Failure delivery, re-entrancy and per-run identity of the shared Azure Voice
/// Live client. No lock is held while a host callback runs, so callbacks may
/// start, cancel or finish the client, and a failure is always published before
/// any finish returns, including a finish that starts while it is delivered.
final class AzureVoiceLiveFailureTests: XCTestCase {
    func testAFailureIsDeliveredBeforeARegisteredFinishReturnsAndMayStartAReplacement() async {
        let fixture = AzureVoiceLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = AzureFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = fixture.socket
        fixture.becomeReady()
        client.sendAudio(AzureVoiceLiveFixture.frame(0))
        old.completeSend()
        old.committed("a")
        old.completed("Saved.", item: "a")
        let committing = expectation(description: "The commit proves the finish is registered")
        old.fulfillOnCommit(committing)
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [committing], timeout: 2)
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        assertReplacementAcceptsAudio(fixture)
    }

    /// The run is closed before its error is published. A finish that starts
    /// while that callback is suspended joins behind it rather than returning
    /// the closed run's text as if it had succeeded.
    func testAFinishThatStartsWhileTheErrorIsDeliveredCannotReturnFirst() async {
        let fixture = AzureVoiceLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered")
        let errorCompleted = expectation(description: "Error callback returned")
        let prematurelyReturned = expectation(description: "A late finish cannot overtake the error")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "The late finish returns after the error")
        let gate = AzureFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let socket = fixture.socket
        fixture.becomeReady()
        socket.committed("a")
        socket.completed("Saved.", item: "a")
        DispatchQueue.global().async { socket.fail() }
        await fulfillment(of: [errorEntered], timeout: 2)
        let late = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fixture.settle { client.queuedDeliveryCount == 1 }
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await late.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testCallbacksMayCancelAndFinishTheClientWithoutDeadlock() async {
        let fixture = AzureVoiceLiveFixture()
        let client = fixture.client
        let finished = expectation(description: "A finish started from the callback returns")
        let result = AzureLockedValue<String?>(nil)
        client.start(onTranscript: { _, isFinal in
            guard isFinal else { return }
            client.cancel()
            Task {
                result.set(await client.finishAndWait())
                finished.fulfill()
            }
        }, onError: { XCTFail("Unexpected error: \($0)") })
        let socket = fixture.socket
        fixture.becomeReady()
        socket.committed("a")
        socket.completed("First.", item: "a")
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(result.value, "First.")
        XCTAssertEqual(socket.cancels, 1)
        socket.completed("Late.", item: "b")
        socket.fail()
        client.sendAudio(AzureVoiceLiveFixture.frame(0))
        XCTAssertTrue(socket.audio.isEmpty)
    }

    func testATranscriptCallbackMayStartAReplacementAndTheOldRunStaysRetired() {
        let fixture = AzureVoiceLiveFixture()
        let client = fixture.client
        let replacementEvents = AssemblyAITestEvents()
        let restarted = AzureLockedValue(false)
        client.start(onTranscript: { _, isFinal in
            guard isFinal, !restarted.value else { return }
            restarted.set(true)
            client.start(onTranscript: { replacementEvents.transcript($0, final: $1) },
                         onError: { replacementEvents.fail($0) })
        }, onError: { XCTFail("The retired run must not report: \($0)") })
        let old = fixture.socket
        fixture.becomeReady()
        client.sendAudio(AzureVoiceLiveFixture.frame(0))
        old.committed("a")
        old.completed("One.", item: "a")
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(old.cancels, 1)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.azureAcknowledge()
        old.completeSend()
        old.azureAcknowledge()
        old.completed("Stale.", item: "b")
        old.fail()
        fixture.clock.fire(AzureVoiceLiveClient.readyDeadline)
        fixture.clock.fire(AzureVoiceLiveClient.sendDeadline)
        XCTAssertTrue(client.isSessionReady)
        replacement.committed("r")
        replacement.completed("Fresh.", item: "r")
        XCTAssertEqual(replacementEvents.texts, ["Fresh."])
        XCTAssertTrue(replacementEvents.errors.isEmpty)
        XCTAssertEqual(replacement.cancels, 0)
        client.cancel()
    }

    func testLateCallbacksFromAReplacedRunCannotTouchItsReplacement() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let replacementEvents = AssemblyAITestEvents()
        fixture.client.start(onTranscript: { replacementEvents.transcript($0, final: $1) },
                             onError: { replacementEvents.fail($0) })
        XCTAssertEqual(old.cancels, 1)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.azureAcknowledge()
        old.completeSend()
        old.committed("x")
        old.completed("Stale.", item: "x")
        old.fail()
        fixture.clock.fire(AzureVoiceLiveClient.sendDeadline)
        fixture.clock.fire(AzureVoiceLiveClient.readyDeadline)
        let limit = AzureVoiceLiveClient.maximumQueuedBytes / AzureVoiceLiveProtocol.frameBytes
        for index in 0..<limit { fixture.client.sendAudio(AzureVoiceLiveFixture.frame(index)) }
        XCTAssertTrue(replacementEvents.errors.isEmpty, "The old frame in flight does not count against the new run")
        XCTAssertTrue(replacementEvents.texts.isEmpty)
        XCTAssertTrue(fixture.events.errors.isEmpty, "A replaced run reports nothing")
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.audio.count, 1)
        fixture.client.cancel()
    }

    func testCancellationWakesAWaitingFinishWithConfirmedTextAndNoError() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        socket.committed("a")
        socket.completed("Kept.", item: "a")
        socket.committed("b")
        socket.delta("draft", item: "b")
        let committing = expectation(description: "Finish registered")
        socket.fulfillOnCommit(committing)
        let finish = fixture.finish()
        await fulfillment(of: [committing], timeout: 2)
        fixture.client.cancel()
        let text = await finish.value
        XCTAssertEqual(text, "Kept.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "Cancellation is not a failure")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testCancellingTheFinishingTaskAbortsTheRun() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.completeSend()
        socket.committed("a")
        socket.completed("Kept.", item: "a")
        let committing = expectation(description: "Finish registered")
        socket.fulfillOnCommit(committing)
        let finish = fixture.finish()
        await fulfillment(of: [committing], timeout: 2)
        finish.cancel()
        let text = await finish.value
        XCTAssertEqual(text, "Kept.")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAReplacementWakesTheRetiredRunsFinish() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        old.completeSend()
        old.committed("a")
        old.completed("Old.", item: "a")
        let committing = expectation(description: "Finish registered")
        old.fulfillOnCommit(committing)
        let finish = fixture.finish()
        await fulfillment(of: [committing], timeout: 2)
        fixture.start()
        let text = await finish.value
        XCTAssertEqual(text, "Old.")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(fixture.factory.sockets[1].cancels, 0)
        fixture.client.cancel()
    }

    func testATransportFailurePublishesOnceAndKeepsConfirmedTextApartFromTheDraft() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("a")
        socket.completed("Kept.", item: "a")
        socket.committed("b")
        socket.delta("draft", item: "b")
        XCTAssertEqual(fixture.events.texts, ["Kept.", "Kept. draft"])
        socket.fail()
        XCTAssertEqual((fixture.events.errors.first as? URLError)?.code, .networkConnectionLost)
        socket.completed("Late.", item: "b")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        XCTAssertEqual(fixture.events.errors.count, 1)
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Kept.", "Only confirmed text is returned after a failure")
    }

    func testARunRetiredBeforeItsSocketIsAttachedNeverResumesIt() {
        let sockets = AzureRetiringFactory()
        let client = AzureVoiceLiveClient(
            credentials: AzureVoiceLiveFixture.credentials, endpoint: AzureVoiceLiveFixture.endpoint,
            model: "mai-transcribe", language: nil, makeConnection: { sockets.make($0) }, schedule: { _, _ in }
        )
        sockets.client = client
        let errors = AssemblyAITestEvents()
        client.start(onTranscript: { _, _ in }, onError: { errors.fail($0) })
        let socket = sockets.made
        XCTAssertEqual(socket?.resumes, 0, "No request leaves for a retired run")
        XCTAssertEqual(socket?.receives, 0)
        XCTAssertEqual(socket?.cancels, 1)
        XCTAssertTrue(errors.errors.isEmpty)
    }

    private func assertReplacementAcceptsAudio(_ fixture: AzureVoiceLiveFixture) {
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.azureAcknowledge()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.audio.count, 1)
        fixture.client.cancel()
    }
}

private final class AzureFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}

private final class AzureLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

/// Cancels the client while its socket is being created, as a concurrent stop
/// would, and records whether that socket was ever resumed.
private final class AzureRetiringFactory: @unchecked Sendable {
    weak var client: AzureVoiceLiveClient?
    private(set) var made: AzureCountingSocket?

    func make(_ request: URLRequest) -> AzureCountingSocket {
        client?.cancel()
        let socket = AzureCountingSocket()
        made = socket
        return socket
    }
}

private final class AzureCountingSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (resumes: 0, receives: 0, cancels: 0)
    var resumes: Int { lock.withLock { counts.resumes } }
    var receives: Int { lock.withLock { counts.receives } }
    var cancels: Int { lock.withLock { counts.cancels } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { counts.resumes += 1 } }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        completion(CancellationError())
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { counts.receives += 1 }
    }
    func cancel() { lock.withLock { counts.cancels += 1 } }
}
