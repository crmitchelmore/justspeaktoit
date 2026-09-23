import Foundation
import XCTest
@testable import SpeakCore

extension SonioxPortableLifecycleTests {
    // MARK: - Explicit errors before success

    func testServerErrorFrameFailsTheRunOnceAndRetainsBestAvailableText() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Partial.", final: true)]))
        socket.emit(#"{"tokens":[],"error_code":503,"error_type":"service_unavailable","error_message":"boom"}"#)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.errors.first as? SonioxStreamingError, .server(code: 503, message: "boom"))
        XCTAssertEqual(socket.cancels, 1)
        // A late frame after the single failure is ignored.
        socket.emit(Self.tokens([(text: "Late.", final: true)]))
        XCTAssertEqual(fixture.events.errors.count, 1)
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Partial.", "The best available text survives the failure")
    }

    func testUnauthorizedErrorFrameMapsToAnInvalidKeyMessage() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(#"{"tokens":[],"error_code":401,"error_message":"invalid api key"}"#)
        guard case StreamingClientError.invalidAPIKey? = fixture.events.errors.first else {
            return XCTFail("A 401 error frame should map to an invalid-key message")
        }
    }

    func testMalformedFramesAreIgnoredWithoutFailingTheRun() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit("not json at all")
        socket.emit(#"{"unexpected":true}"#)
        socket.emit(Self.tokens([(text: "Kept.", final: true)]))
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected)
        fixture.client.cancel()
    }

    func testFailureIsPublishedBeforeFinishReturnsAndMayStartAReplacement() async {
        let fixture = SonioxLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered on the provider queue")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = SonioxFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = fixture.socket
        old.open()
        old.completeSend() // config
        old.emit(Self.tokens([(text: "Saved.", final: true)]))
        let finishing = expectation(description: "End-of-stream proves the finish waiter is registered")
        old.onSend = { message in if case .binary(let data) = message, data.isEmpty { finishing.fulfill() } }
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finishing], timeout: 2)
        DispatchQueue.global().async { old.fail() }
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
        replacement.emit(Self.tokens([(text: "Fresh", final: false)]))
        XCTAssertEqual(replacement.cancels, 0)
        client.cancel()
    }
}

private final class SonioxFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
