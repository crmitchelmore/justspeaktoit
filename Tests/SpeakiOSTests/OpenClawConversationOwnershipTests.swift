#if os(iOS)
import Foundation
import SpeakCore
@testable import SpeakiOSLib
import XCTest

@MainActor
final class OpenClawConversationOwnershipTests: XCTestCase {
    func testHeldReadinessAndConversationSwitchCannotSendOrRestoreOldSelection() async {
        let (fixture, coordinator) = makeFixture()
        let gate = fixture.gate()
        fixture.readyGate = gate
        coordinator.selectConversation(fixture.first)
        let done = launchSend("first", coordinator: coordinator, fixture: fixture)
        guard await settled(gate.entered) else { return }
        coordinator.selectConversation(fixture.second)
        gate.release()
        guard await settled(done) else { return }
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertTrue(fixture.messages(fixture.first).isEmpty)
        XCTAssertTrue(fixture.messages(fixture.second).isEmpty)
        XCTAssertNil(coordinator.error)
    }

    func testCancelledWaitingCallerCannotRetireNewerAcceptedSend() async {
        let (fixture, coordinator) = makeFixture()
        let gate = fixture.gate()
        fixture.readyGate = gate
        coordinator.selectConversation(fixture.first)
        let done = XCTestExpectation(description: "Cancelled sender returned")
        let task = launchSend("old", done: done, coordinator: coordinator, fixture: fixture)
        guard await settled(gate.entered) else { return }
        task.cancel()
        coordinator.selectConversation(fixture.second)
        fixture.readyGate = nil
        await coordinator.sendTextMessage("new")
        fixture.acknowledge(0, .success("new-run"))
        gate.release()
        guard await settled(done) else { return }
        XCTAssertEqual(fixture.sends.map(\.text), ["new"])
        XCTAssertEqual(coordinator.currentRunId, "new-run")
        XCTAssertTrue(coordinator.isProcessing)
        XCTAssertNil(coordinator.error)
    }

    func testOldAcknowledgmentAndEventsCannotAttachToReplacementConversation() async {
        let (fixture, coordinator) = makeFixture()
        coordinator.selectConversation(fixture.first)
        await coordinator.sendTextMessage("old")
        coordinator.selectConversation(fixture.second)
        await coordinator.sendTextMessage("new")
        fixture.acknowledge(1, .success("new-run"))
        fixture.callbacks?.delta("new-run", "current partial")
        fixture.acknowledge(0, .success("old-run"))
        fixture.acknowledge(0, .failure(CancellationError()))
        fixture.callbacks?.delta("old-run", "old partial")
        fixture.callbacks?.final("old-run", "old result")
        fixture.callbacks?.error("old-run", "old error")
        XCTAssertEqual(coordinator.currentRunId, "new-run")
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertEqual(coordinator.streamingResponse, "current partial")
        XCTAssertEqual(fixture.messages(fixture.second).map(\.content), ["new"])
        XCTAssertNil(coordinator.error)
        XCTAssertTrue(fixture.spoken.isEmpty)
        XCTAssertEqual(fixture.resumes, 0)
        XCTAssertEqual(fixture.activityUpdates, 0)
    }

    func testDisconnectRetiresAcceptedRunWithoutLateSpeechOrResume() async {
        let (fixture, coordinator) = makeFixture()
        coordinator.selectConversation(fixture.first)
        await coordinator.sendTextMessage("request")
        fixture.acknowledge(0, .success("retired"))
        coordinator.stopAllAndDisconnect()
        let activityCount = fixture.activityUpdates
        fixture.callbacks?.delta("retired", "late")
        fixture.callbacks?.final("retired", "late final")
        fixture.callbacks?.error("retired", "late error")
        fixture.acknowledge(0, .success("retired"))
        XCTAssertEqual(fixture.messages(fixture.first).map(\.role), ["user"])
        XCTAssertFalse(coordinator.isProcessing)
        XCTAssertNil(coordinator.currentRunId)
        XCTAssertNil(coordinator.error)
        XCTAssertTrue(fixture.spoken.isEmpty)
        XCTAssertEqual(fixture.resumes, 0)
        XCTAssertEqual(fixture.activityUpdates, activityCount)
    }

    func testCurrentConnectionLossRetiresAcceptedRunAndLateReplies() async {
        for state in [OpenClawClient.ConnectionState.disconnected, .error("connection lost")] {
            let (fixture, coordinator) = makeFixture()
            coordinator.selectConversation(fixture.first)
            await coordinator.sendTextMessage("request")
            fixture.acknowledge(0, .success("retired"))
            fixture.callbacks?.connection(state)
            let publishedError = coordinator.error?.localizedDescription
            fixture.callbacks?.delta("retired", "late partial")
            fixture.callbacks?.final("retired", "late final")
            fixture.callbacks?.error("retired", "late error")
            fixture.acknowledge(0, .success("retired"))
            XCTAssertNil(coordinator.currentRunId)
            XCTAssertFalse(coordinator.isProcessing)
            XCTAssertTrue(coordinator.streamingResponse.isEmpty)
            XCTAssertEqual(fixture.messages(fixture.first).map(\.content), ["request"])
            XCTAssertEqual(coordinator.error?.localizedDescription, publishedError)
            XCTAssertTrue(fixture.spoken.isEmpty)
            XCTAssertEqual(fixture.resumes, 0)
        }
    }

    func testOldConnectionPacketCannotRetireReconnectedNewOwner() async {
        let (fixture, coordinator) = makeFixture()
        coordinator.selectConversation(fixture.first)
        let old = fixture.callbacks
        coordinator.disconnect()
        coordinator.selectConversation(fixture.second)
        await coordinator.sendTextMessage("new")
        fixture.acknowledge(0, .success("new-run"))
        old?.connection(.disconnected)
        old?.connection(.error("old connection error"))
        guard case .connected = coordinator.connectionState else {
            XCTFail("Stale packet changed the current connection")
            return
        }
        XCTAssertEqual(coordinator.currentRunId, "new-run")
        XCTAssertTrue(coordinator.isProcessing)
        XCTAssertEqual(coordinator.currentConversation?.id, fixture.second.id)
        XCTAssertEqual(fixture.messages(fixture.second).map(\.content), ["new"])
        XCTAssertNil(coordinator.error)
    }

    func testDuplicateFinalIsIgnoredButIdenticalTextInAnotherRunIsPersisted() async {
        let (fixture, coordinator) = makeFixture()
        coordinator.selectConversation(fixture.first)
        for index in 0..<2 {
            let resumed = XCTestExpectation(description: "Current response resumed")
            fixture.onResume = { resumed.fulfill() }
            await coordinator.sendTextMessage("request \(index)")
            fixture.acknowledge(index, .success("run-\(index)"))
            fixture.callbacks?.final("run-\(index)", "same reply")
            fixture.callbacks?.final("run-\(index)", "same reply")
            guard await settled(resumed) else { return }
        }
        XCTAssertEqual(fixture.messages(fixture.first).map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(fixture.messages(fixture.first).filter { $0.role == "assistant" }.map(\.content),
                       ["same reply", "same reply"])
        XCTAssertEqual(fixture.resumes, 2)
    }

    func testValidStreamSegmentsKeepOrderAndSpeakOneOwnedBatch() async {
        let (fixture, coordinator) = makeFixture()
        fixture.canSpeak = true
        coordinator.selectConversation(fixture.first)
        let resumed = XCTestExpectation(description: "Response effects completed")
        fixture.onResume = { resumed.fulfill() }
        await coordinator.sendTextMessage("request")
        fixture.acknowledge(0, .success("run"))
        fixture.callbacks?.delta("run", "First segment.")
        fixture.callbacks?.delta("run", "Second segment.")
        fixture.callbacks?.final("run", "Second segment.")
        guard await settled(resumed) else { return }
        XCTAssertEqual(fixture.messages(fixture.first).map(\.content),
                       ["request", "First segment.", "Second segment."])
        XCTAssertEqual(fixture.spoken, [["First segment.", "Second segment."]])
        XCTAssertEqual(fixture.activityUpdates, 1)
        XCTAssertFalse(coordinator.isBufferingForTTS)
    }

    func testHeldOldSpeechCompletionCannotResumeOrClearNewRun() async {
        let (fixture, coordinator) = makeFixture()
        let gate = fixture.gate()
        fixture.canSpeak = true
        fixture.speechGate = gate
        coordinator.selectConversation(fixture.first)
        await coordinator.sendTextMessage("old")
        fixture.acknowledge(0, .success("old-run"))
        fixture.callbacks?.final("old-run", "old reply")
        guard await settled(gate.entered) else { return }
        let exited = watchResponse(coordinator, fixture: fixture)
        coordinator.selectConversation(fixture.second)
        await coordinator.sendTextMessage("new")
        fixture.acknowledge(1, .success("new-run"))
        fixture.callbacks?.delta("new-run", "new partial")
        gate.release()
        guard await settled(exited) else { return }
        XCTAssertEqual(coordinator.currentRunId, "new-run")
        XCTAssertEqual(coordinator.streamingResponse, "new partial")
        XCTAssertTrue(coordinator.isProcessing)
        XCTAssertTrue(coordinator.isBufferingForTTS)
        XCTAssertEqual(fixture.resumes, 0)
        XCTAssertEqual(fixture.spoken, [["old reply"]])
        XCTAssertEqual(fixture.messages(fixture.second).map(\.content), ["new"])
    }

    func testAlreadyCancelledQueuedSendDoesNotStopCurrentResponse() async {
        let (fixture, coordinator) = makeFixture()
        let speech = fixture.gate()
        fixture.canSpeak = true
        fixture.speechGate = speech
        coordinator.selectConversation(fixture.second)
        await coordinator.sendTextMessage("valid")
        fixture.acknowledge(0, .success("valid-run"))
        fixture.callbacks?.final("valid-run", "valid reply")
        guard await settled(speech.entered) else { return }
        let queued = fixture.gate()
        let done = XCTestExpectation(description: "Cancelled queued request returned")
        let task = launchSend("cancelled", before: queued, done: done,
                              coordinator: coordinator, fixture: fixture)
        guard await settled(queued.entered) else { return }
        let stops = fixture.speechStops
        task.cancel()
        queued.release()
        guard await settled(done) else { return }
        XCTAssertEqual(fixture.sends.map(\.text), ["valid"])
        XCTAssertEqual(fixture.speechStops, stops)
        XCTAssertEqual(fixture.spoken, [["valid reply"]])
        XCTAssertEqual(fixture.resumes, 0)
    }

    func testDeletedConversationCannotAcceptWaitingSend() async {
        let (fixture, coordinator) = makeFixture()
        let gate = fixture.gate()
        fixture.readyGate = gate
        coordinator.selectConversation(fixture.first)
        let done = launchSend("request", coordinator: coordinator, fixture: fixture)
        guard await settled(gate.entered) else { return }
        fixture.rows.removeValue(forKey: fixture.first.id)
        gate.release()
        guard await settled(done) else { return }
        XCTAssertTrue(fixture.sends.isEmpty)
        XCTAssertTrue(fixture.messages(fixture.second).isEmpty)
    }

}

private extension OpenClawConversationOwnershipTests {
    func makeFixture() -> (OpenClawOwnershipFixture, OpenClawChatCoordinator) {
        let fixture = OpenClawOwnershipFixture()
        let coordinator = fixture.makeCoordinator()
        addTeardownBlock {
            let response = await MainActor.run {
                let response = coordinator.responseTask
                coordinator.stopAllAndDisconnect()
                fixture.releaseAll()
                return response
            }
            if let response {
                let exited = XCTestExpectation(description: "Current response exited in cleanup")
                let observer = Task { await response.value; exited.fulfill() }
                let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
                observer.cancel()
                XCTAssertEqual(result, .completed)
            }
        }
        return (fixture, coordinator)
    }

    func settled(
        _ expectation: XCTestExpectation, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
    }

    func launchSend(
        _ text: String, coordinator: OpenClawChatCoordinator, fixture: OpenClawOwnershipFixture
    ) -> XCTestExpectation {
        let done = XCTestExpectation(description: "Owned sender returned")
        _ = launchSend(text, done: done, coordinator: coordinator, fixture: fixture)
        return done
    }

    @discardableResult
    func launchSend(
        _ text: String, before gate: OpenClawOwnershipGate? = nil, done: XCTestExpectation,
        coordinator: OpenClawChatCoordinator, fixture: OpenClawOwnershipFixture
    ) -> Task<Void, Never> {
        let exited = XCTestExpectation(description: "Owned sender exited")
        let task = Task { @MainActor in
            defer { exited.fulfill() }
            await gate?.wait()
            await coordinator.sendTextMessage(text)
            done.fulfill()
        }
        addTeardownBlock {
            task.cancel()
            await MainActor.run { fixture.releaseAll() }
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(result, .completed)
        }
        return task
    }

    func watchResponse(
        _ coordinator: OpenClawChatCoordinator, fixture: OpenClawOwnershipFixture
    ) -> XCTestExpectation {
        let done = XCTestExpectation(description: "Retired response task exited")
        guard let response = coordinator.responseTask else {
            XCTFail("Expected the signalled response task to remain owned")
            return done
        }
        let exited = XCTestExpectation(description: "Response observer exited")
        let observer = Task {
            defer { exited.fulfill() }
            await response.value
            done.fulfill()
        }
        addTeardownBlock {
            response.cancel()
            await MainActor.run {
                coordinator.stopAllAndDisconnect()
                fixture.releaseAll()
            }
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            observer.cancel()
            XCTAssertEqual(result, .completed)
        }
        return done
    }
}
#endif
