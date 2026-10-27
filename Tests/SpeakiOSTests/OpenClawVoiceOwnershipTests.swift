#if os(iOS)
import Foundation
import SpeakCore
@testable import SpeakiOSLib
import XCTest

/// Inert capture boundary: no recorder, audio session, settings or provider is constructed.
@MainActor
final class OpenClawVoiceCaptureFixture: OpenClawVoiceCapture {
    private var liveText = ""
    var onPartialRead: (() -> Void)?
    var partialText: String {
        get {
            let callback = onPartialRead
            onPartialRead = nil
            callback?()
            return liveText
        }
        set { liveText = newValue }
    }
    var resultText = "spoken request"
    var stopGate: OpenClawOwnershipGate?
    var starts = 0
    var stops = 0
    var cancellations = 0
    var stopWasCancelled: Bool?

    func startCapture() async throws { starts += 1 }
    func stopCapture() async -> TranscriptionResult {
        stops += 1
        stopWasCancelled = Task.isCancelled
        await stopGate?.wait()
        return TranscriptionResult(text: resultText, segments: [], confidence: nil, duration: 1,
                                   modelIdentifier: "fixture", cost: nil, rawPayload: nil, debugInfo: nil)
    }
    func cancelCapture() { cancellations += 1 }
}

@MainActor
final class OpenClawVoiceOwnershipTests: XCTestCase {
    func testHeldVoiceStopCannotSendIntoSwitchedConversation() async throws {
        let (fixture, coordinator) = makeFixture()
        let capture = OpenClawVoiceCaptureFixture()
        let gate = fixture.gate()
        capture.stopGate = gate
        fixture.voiceCaptures = [capture]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        let done = launch(fixture, coordinator: coordinator) { await coordinator.stopVoiceInputAndSend() }
        guard await settled(gate.entered) else { return }
        coordinator.selectConversation(fixture.second)
        gate.release()
        guard await settled(done) else { return }
        XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertTrue(fixture.messages(fixture.first).isEmpty)
        XCTAssertTrue(fixture.messages(fixture.second).isEmpty)
        XCTAssertNil(coordinator.error)
    }

    func testConversationSwitchBeforeStopCannotSendOldCaptureIntoNewRow() async throws {
        let (fixture, coordinator) = makeFixture()
        let capture = OpenClawVoiceCaptureFixture()
        fixture.voiceCaptures = [capture]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        coordinator.selectConversation(fixture.second)
        await coordinator.stopVoiceInputAndSend()
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertTrue(fixture.messages(fixture.first).isEmpty)
        XCTAssertTrue(fixture.messages(fixture.second).isEmpty)
        XCTAssertNil(coordinator.error)
    }

    func testSwitchedConversationRetiresActualPartialMonitorBeforeAnotherPublication() async throws {
        let (fixture, coordinator) = makeFixture()
        let capture = OpenClawVoiceCaptureFixture()
        let read = XCTestExpectation(description: "Actual monitor read the owned partial")
        capture.partialText = "owned first partial"
        capture.onPartialRead = { read.fulfill() }
        fixture.voiceCaptures = [capture]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        guard let monitor = coordinator.recordingMonitorTask else {
            XCTFail("Expected the owned monitor")
            return
        }
        guard await settled(read) else { return }
        XCTAssertEqual(coordinator.partialTranscript, "owned first partial")
        coordinator.selectConversation(fixture.second)
        capture.partialText = "retired late partial"
        let done = launch(fixture, coordinator: coordinator) { await monitor.value }
        guard await settled(done) else { return }
        XCTAssertTrue(coordinator.partialTranscript.isEmpty)
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertEqual(capture.stops, 0)
        XCTAssertEqual(capture.cancellations, 0)
        XCTAssertNil(coordinator.error)
    }

    func testRetiredVoiceStopCannotClearNewCaptureOwner() async throws {
        let (fixture, coordinator) = makeFixture()
        let old = OpenClawVoiceCaptureFixture()
        let current = OpenClawVoiceCaptureFixture()
        let gate = fixture.gate()
        old.stopGate = gate
        fixture.voiceCaptures = [old, current]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        let done = launch(fixture, coordinator: coordinator) { await coordinator.stopVoiceInputAndSend() }
        guard await settled(gate.entered) else { return }
        coordinator.cancelVoiceInput()
        coordinator.selectConversation(fixture.second)
        try await coordinator.startVoiceInput()
        gate.release()
        guard await settled(done) else { return }
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(current.starts, 1)
        XCTAssertEqual(current.stops, 0)
        XCTAssertEqual(current.cancellations, 0)
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        coordinator.cancelVoiceInput()
        XCTAssertEqual(current.cancellations, 1)
    }

    func testKeywordMonitorHandsOffWithoutCancellingItsOwnStop() async throws {
        let (fixture, coordinator) = makeFixture()
        let capture = OpenClawVoiceCaptureFixture()
        let gate = fixture.gate()
        capture.partialText = "spoken request over"
        capture.resultText = "spoken request over"
        capture.stopGate = gate
        fixture.policy = OpenClawConversationPolicy(conversationModeEnabled: true,
                                                    keywordAcknowledgeEnabled: true,
                                                    keywordAcknowledgePhrase: "over")
        fixture.voiceCaptures = [capture]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        guard let monitor = coordinator.recordingMonitorTask else {
            XCTFail("Expected the newly installed owned monitor")
            return
        }
        let done = launch(fixture, coordinator: coordinator) { await monitor.value }
        guard await settled(gate.entered) else { return }
        XCTAssertEqual(capture.stopWasCancelled, false)
        XCTAssertEqual(capture.stops, 1)
        gate.release()
        guard await settled(done) else { return }
        XCTAssertEqual(fixture.sends.map(\.text), ["spoken request"])
        XCTAssertEqual(fixture.sends.map(\.sessionKey), [fixture.first.sessionKey])
        XCTAssertEqual(fixture.messages(fixture.first).map(\.content), ["spoken request"])
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.isProcessing)
        XCTAssertNil(coordinator.error)
    }

    func testAlreadyCancelledQueuedVoiceStartDoesNotCancelCurrentCapture() async throws {
        let (fixture, coordinator) = makeFixture()
        let capture = OpenClawVoiceCaptureFixture()
        fixture.voiceCaptures = [capture]
        coordinator.selectConversation(fixture.first)
        try await coordinator.startVoiceInput()
        let gate = fixture.gate()
        let done = XCTestExpectation(description: "Cancelled queued voice start returned")
        let task = Task { @MainActor in
            await gate.wait()
            do {
                try await coordinator.startVoiceInput()
                XCTFail("Cancelled voice start must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        addTeardownBlock {
            task.cancel()
            await MainActor.run { fixture.releaseAll() }
            let exited = XCTestExpectation(description: "Queued voice task exited")
            let observer = Task { await task.value; exited.fulfill() }
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            observer.cancel()
            XCTAssertEqual(result, .completed)
        }
        guard await settled(gate.entered) else { return }
        task.cancel()
        gate.release()
        guard await settled(done) else { return }
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(fixture.voiceAllocations, 1)
        XCTAssertEqual(capture.cancellations, 0)
        XCTAssertEqual(capture.stops, 0)
        XCTAssertTrue(fixture.sends.isEmpty)
    }
}

private extension OpenClawVoiceOwnershipTests {
    func makeFixture() -> (OpenClawOwnershipFixture, OpenClawChatCoordinator) {
        let fixture = OpenClawOwnershipFixture()
        let coordinator = fixture.makeCoordinator()
        addTeardownBlock {
            let monitor = await MainActor.run {
                let monitor = coordinator.recordingMonitorTask
                coordinator.stopAllAndDisconnect()
                fixture.releaseAll()
                return monitor
            }
            if let monitor {
                let exited = XCTestExpectation(description: "Owned monitor exited")
                let observer = Task { await monitor.value; exited.fulfill() }
                let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
                observer.cancel()
                XCTAssertEqual(result, .completed)
            }
        }
        return (fixture, coordinator)
    }

    func settled(_ expectation: XCTestExpectation) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed)
        return result == .completed
    }

    func launch(
        _ fixture: OpenClawOwnershipFixture, coordinator: OpenClawChatCoordinator,
        operation: @escaping @MainActor () async -> Void
    ) -> XCTestExpectation {
        let done = XCTestExpectation(description: "Owned voice operation completed")
        let exited = XCTestExpectation(description: "Owned voice task exited")
        let task = Task { @MainActor in
            defer { exited.fulfill() }
            await operation()
            done.fulfill()
        }
        addTeardownBlock {
            task.cancel()
            await MainActor.run {
                coordinator.stopAllAndDisconnect()
                fixture.releaseAll()
            }
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(result, .completed)
        }
        return done
    }
}
#endif
