import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class OpenAIRealtimeFailureTests: XCTestCase {
    func testFailureIsPublishedBeforeFinishReturnsAndMayStartAReplacement() async {
        let fixture = OpenAIRealtimeLiveFixture()
        let client = fixture.client
        let errorEntered = expectation(description: "Error callback entered on the provider queue")
        let errorCompleted = expectation(description: "Error delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = OpenAIFinishGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = fixture.socket
        fixture.becomeReady()
        old.completed("Saved.", item: "item_1")
        client.sendAudio(Data(repeating: 0, count: 4_800))
        let finishing = expectation(description: "Commit proves the finish waiter is registered")
        old.fulfillOnCommit(finishing)
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        old.completeSend()
        await fulfillment(of: [finishing], timeout: 2)
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

    private func assertReplacementAcceptsAudio(_ fixture: OpenAIRealtimeLiveFixture) {
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.completeSend()
        replacement.acknowledge()
        fixture.client.sendAudio(Data(repeating: 0, count: 4_800))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.audio.count, 1)
        fixture.client.cancel()
    }

    func testCancellingAnOldFinishCannotCloseTheReplacement() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        old.completeSend()
        let committing = expectation(description: "Finish reached the commit")
        old.fulfillOnCommit(committing)
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [committing], timeout: 2)
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        finish.cancel()
        _ = await finish.value
        replacement.open()
        replacement.completeSend()
        replacement.acknowledge()
        fixture.client.sendAudio(Data(repeating: 0, count: 4_800))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.audio.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testServerErrorWhileAwaitingTheCommittedItemEndsTheFinishVisibly() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.delta("Partial", item: "item_1")
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.types.last == "input_audio_buffer.commit" }
        socket.completeSend()
        socket.serverError(code: "input_audio_buffer_commit_empty", message: "buffer too small")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Partial", "The best available text survives the failure")
        XCTAssertEqual(
            fixture.events.errors.first as? OpenAIRealtimeStreamingError,
            .serverError(code: "input_audio_buffer_commit_empty", message: "buffer too small")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testServerErrorsAreReportedWithoutClosingUntilACommitIsInTransport() {
        let early = OpenAIRealtimeLiveFixture()
        early.start()
        let prefix = Data(repeating: 1, count: 4_800)
        early.client.sendAudio(prefix)
        early.socket.open()
        early.socket.completeSend()
        early.socket.serverError(code: "invalid_value", message: "unknown field")
        XCTAssertEqual(early.events.errors.count, 1)
        XCTAssertEqual(early.socket.cancels, 0, "The session stays open; readiness is still awaited")
        early.socket.acknowledge()
        XCTAssertEqual(early.socket.audio, [prefix], "A later acknowledgement still releases the prefix")
        early.client.cancel()

        let live = OpenAIRealtimeLiveFixture()
        live.start()
        live.becomeReady()
        live.socket.serverError()
        XCTAssertEqual(live.events.errors.count, 1)
        XCTAssertEqual(live.socket.cancels, 0, "Recoverable errors leave the session open")
        XCTAssertTrue(live.client.isReady)
        live.client.sendAudio(Data(repeating: 1, count: 4_800))
        XCTAssertEqual(live.socket.audio.count, 1)
        live.client.cancel()
    }

    func testTranscriptionFailureForTheCommittedItemEndsTheFinishWithTheError() async {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(Data(repeating: 1, count: 4_800))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.types.last == "input_audio_buffer.commit" }
        socket.completeSend()
        socket.committed("item_1")
        socket.transcriptionFailed(item: "item_1", message: "unintelligible")
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(
            fixture.events.errors.first as? OpenAIRealtimeStreamingError,
            .transcriptionFailed(itemID: "item_1", message: "unintelligible")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testConcurrentAcknowledgementOverflowAndCancelStayBoundedAndReportAtMostOnce() {
        for _ in 0..<30 {
            let socket = OpenAIRealtimeAutoSocket()
            let events = AssemblyAITestEvents()
            let client = OpenAIRealtimeLiveClient(
                apiKey: "synthetic", model: "gpt-live-transcribe", makeConnection: { _ in socket }
            )
            client.start(onTranscript: { _, _ in }, onError: { [events] in events.fail($0) })
            client.sendAudio(Data(repeating: 0, count: 240_000))
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0: client.sendAudio(Data(repeating: 1, count: 4_800))
                case 1: socket.acknowledge()
                default: client.cancel()
                }
            }
            XCTAssertLessThanOrEqual(events.errors.count, 1)
            XCTAssertEqual(client.queuedAudioByteCount, 0)
            XCTAssertTrue(socket.isCancelled)
            XCTAssertLessThanOrEqual(socket.sent.count, 3, "session.update, the prefix and at most one live frame")
        }
    }

    func testReceiveFailureAfterCancelAndOverflowCallbackStoppingTheRunAreBothSafe() {
        let fixture = OpenAIRealtimeLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.cancel()
        fixture.socket.fail()
        XCTAssertTrue(fixture.events.errors.isEmpty)

        let stopping = OpenAIRealtimeLiveFixture()
        let client = stopping.client
        client.start(onTranscript: { _, _ in }, onError: { [weak client] _ in client?.cancel() })
        stopping.client.sendAudio(Data(repeating: 0, count: 240_000))
        stopping.client.sendAudio(Data(repeating: 0, count: 2))
        XCTAssertEqual(stopping.socket.cancels, 1)
        XCTAssertEqual(stopping.client.queuedAudioByteCount, 0)
        stopping.socket.open()
        stopping.socket.acknowledge()
        XCTAssertTrue(stopping.socket.controls.isEmpty, "A late handshake cannot revive cancelled audio")
    }
}

private final class OpenAIFinishGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
