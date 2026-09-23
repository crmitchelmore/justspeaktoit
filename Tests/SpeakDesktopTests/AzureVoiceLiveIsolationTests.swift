import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Late transport callbacks and timers from a cancelled or replaced run can
/// never deliver, send, fail or finish anything; the run they belonged to is
/// closed and a replacement is untouched by them.
final class AzureVoiceLiveIsolationTests: XCTestCase {
    func testACancelledRunIgnoresLateOpenReceiveSendAndTimerCallbacks() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        socket.committed("item_a")
        socket.delta("Draft", item: "item_a")
        fixture.client.cancel()
        XCTAssertEqual(socket.cancels, 1)
        let sent = socket.controls.count
        socket.completeSend()
        socket.open()
        socket.completed("Too late.", item: "item_a")
        socket.fail()
        fixture.clock.drain().forEach { $0() }
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        XCTAssertEqual(socket.controls.count, sent, "Nothing leaves on behalf of a cancelled run")
        XCTAssertEqual(fixture.events.texts, ["Draft"])
        XCTAssertTrue(fixture.events.errors.isEmpty, "Cancellation is not a provider failure")
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript, "A draft is never returned as a completed transcript")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(fixture.client.isSessionReady)
    }

    func testAReplacementRunIsUntouchedByTheRetiredSocket() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let retired = fixture.socket
        retired.committed("item_a")
        let replacement = AzureVoiceLiveTestRecorder()
        fixture.client.start(onTranscript: { replacement.transcript($0, final: $1) },
                             onError: { replacement.fail($0) })
        XCTAssertEqual(retired.cancels, 1)
        let current = fixture.factory.sockets[1]
        current.open()
        current.completeSend()
        current.acknowledge(sessionType: nil)
        retired.completed("Old words.", item: "item_a")
        retired.azureError(code: "server_error", type: "server_error")
        retired.fail()
        fixture.clock.drain().forEach { $0() }
        XCTAssertTrue(replacement.entries.isEmpty, "The retired socket cannot reach the replacement's host")
        XCTAssertTrue(fixture.events.texts.isEmpty && fixture.events.errors.isEmpty)
        XCTAssertEqual(current.cancels, 0)
        XCTAssertTrue(fixture.client.isSessionReady, "The replacement's readiness is its own")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(3))
        XCTAssertEqual(current.audio, [AzureVoiceLiveFixture.frame(3)])
        current.committed("item_b")
        current.completed("New words.", item: "item_b")
        XCTAssertEqual(replacement.entries, [.transcript("New words.", final: true)])
        fixture.client.cancel()
    }

    func testTheErrorCallbackMayStartAReplacementBeforeTheFinishReturns() async {
        let fixture = AzureVoiceLiveFixture()
        let client = fixture.client
        let gate = AzureVoiceLiveGate()
        let errorEntered = expectation(description: "Error delivered on the client's queue")
        let prematurelyReturned = expectation(description: "The finish cannot return while the error is delivered")
        prematurelyReturned.isInverted = true
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Old cleanup failed the replacement") })
            gate.markDelivered()
        })
        fixture.becomeReady()
        let old = fixture.socket
        old.committed("item_a")
        old.completed("Saved.", item: "item_a")
        client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            return result
        }
        await fixture.waitForFinishers()
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.acknowledge(sessionType: nil)
        client.sendAudio(AzureVoiceLiveFixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.audio, [AzureVoiceLiveFixture.frame(1)])
        client.cancel()
    }

    func testCancellingTheFinishTaskReleasesItPromptlyWithoutAnError() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.completed("Kept.", item: "item_a")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertTrue(fixture.events.errors.isEmpty, "Cancellation is not a provider failure")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testLateTimersFromASettledFinishChangeNothing() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = await fixture.finishThroughBarrier(committing: "item_a")
        socket.acknowledge(sessionType: nil)
        socket.completed("Done.", item: "item_a")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Done.")
        fixture.clock.drain().forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty, "A deadline for a settled finish is inert")
        XCTAssertEqual(socket.cancels, 1)
    }
}

/// Holds an error callback open while the test checks the finish is still waiting.
private final class AzureVoiceLiveGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false

    var delivered: Bool { lock.withLock { deliveredValue } }

    func markDelivered() { lock.withLock { deliveredValue = true } }
}

/// Records one host's callbacks in order.
final class AzureVoiceLiveTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AzureVoiceLiveLog.Entry] = []

    var entries: [AzureVoiceLiveLog.Entry] { lock.withLock { values } }

    func transcript(_ text: String, final: Bool) { lock.withLock { values.append(.transcript(text, final: final)) } }

    func fail(_ error: Error) { lock.withLock { values.append(.error("\(error)")) } }
}
