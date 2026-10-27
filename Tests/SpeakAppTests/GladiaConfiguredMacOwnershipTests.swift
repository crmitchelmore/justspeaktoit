import Foundation
import XCTest
@testable import SpeakApp
@testable import SpeakCore

/// Configured replacements for the remaining four legacy Mac finalization
/// contracts. Positive Core admission/phase receipts precede race assertions.
@MainActor
final class GladiaConfiguredMacOwnershipTests: XCTestCase {
    func testConfiguredCoreAndControllerFinishJoinOneStopAndObserveOwnedCancellation() async throws {
        let fixture = try ConfiguredGladiaControllerFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("Confirmed.", id: "1"))
        let core = fixture.ownFinish(in: self)
        try await fixture.until("first admitted Core waiter") { fixture.client.finishWaiterCount == 1 }
        let stopping = fixture.ownStop(in: self)
        try await fixture.until("Core and controller waiters joined") { fixture.client.finishWaiterCount == 2 }
        try await fixture.advanceGraceToControl()
        XCTAssertFalse(core.settlement.settled)
        XCTAssertFalse(stopping.settlement.settled)
        stopping.task.cancel()
        try await fixture.wait(stopping.done)
        try await fixture.wait(core.done)
        await stopping.task.value
        let confirmed = await core.task.value
        XCTAssertEqual(confirmed, "Confirmed.")
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(socket.controls, [ConfiguredGladiaControllerFixture.stopJSON])
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.delegate.errors.first is CancellationError)
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertFalse(fixture.delegate.events.contains(.boundary("Confirmed.")))
        XCTAssertTrue(fixture.delegate.results.isEmpty)
    }

    func testConfiguredJoinedFinishWaitsForActualHeldFailureCallbackToReturn() async throws {
        let fixture = try ConfiguredGladiaControllerFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("Kept.", id: "1"))
        socket.emit(try frame("draft", id: "2", final: false))
        fixture.updates.deliverAll()
        let stopping = try await fixture.beginStop(in: self)
        let entered = XCTestExpectation(description: "Core failure callback held after host captured active.fail")
        let gate = DispatchSemaphore(value: 0)
        fixture.updatesRelease = { gate.signal() }
        fixture.updates.holdNextEnqueue(entered: entered, release: gate)
        let background = fixture.background(in: self) {
            do {
                try socket.completeSend(URLError(.networkConnectionLost))
            } catch {
                XCTFail("Owned control completion missing: \(error)")
            }
        }
        try await fixture.wait(entered)
        XCTAssertTrue(fixture.client.perform { _ in
            fixture.client.run.stage == .closed && fixture.client.run.reportingFailure
        })
        let joined = fixture.ownFinish(in: self)
        try await fixture.until("joining the held failure report") { fixture.client.finishWaiterCount == 2 }
        XCTAssertFalse(stopping.settlement.settled)
        XCTAssertFalse(joined.settlement.settled)
        let callbackTailReached = ConfiguredGladiaSettlement()
        let stopSettlement = stopping.settlement, joinedSettlement = joined.settlement
        fixture.callbackTail.arm {
            XCTAssertFalse(stopSettlement.settled, "Core cannot resume before its onError callback returns")
            XCTAssertFalse(joinedSettlement.settled)
            callbackTailReached.mark()
        }
        gate.signal()
        try await fixture.wait(background.done)
        try await fixture.wait(joined.done)
        try await fixture.wait(stopping.done)
        XCTAssertTrue(callbackTailReached.settled)
        let result = await joined.task.value
        XCTAssertEqual(result, "Kept.")
        await stopping.task.value
        XCTAssertEqual(fixture.delegate.events, [
            .partial("Kept."), .boundary("Kept."), .partial("Kept. draft"), .error
        ])
        XCTAssertEqual(fixture.delegate.errors.first as? GladiaStreamingError, .connectionLost)
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
    }

    func testConfiguredEarlyEndBeforeActualControlHandoffFailsWithoutSendingClaimedStop() async throws {
        let fixture = try ConfiguredGladiaControllerFixture(grace: 0)
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("Kept.", id: "1"))
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 0)
        let held = XCTestExpectation(description: "actual control arm held before its send effect")
        fixture.clock.holdNext(GladiaConfiguredTiming.control, entered: held)
        let core = fixture.ownFinish(in: self)
        try await fixture.wait(held)
        // Drained + zero grace advances before effects: the drain arm is stale.
        // Prove this is control, not merely the first shared1.5-second delay.
        let controlOwned = fixture.client.perform { _ in
            let run = fixture.client.run
            return run.stage == .open && run.finishPhase == .control && run.finishing
                && run.inFlightAudioBytes == 0 && run.admittedAudioBytes == 0
                && run.admittedAudioChunks == 0 && !run.stopHandedOff
        }
        guard controlOwned else {
            XCTFail("Only the actual drained control phase may drive this pre-handoff fixture")
            throw ConfiguredGladiaControllerFixture.Timeout()
        }
        XCTAssertEqual(fixture.clock.count(GladiaConfiguredTiming.control), 1)
        let stopping = fixture.ownStop(in: self)
        try await fixture.until("two admitted waiters before premature terminal event") {
            fixture.client.finishWaiterCount == 2
        }
        XCTAssertTrue(socket.controls.isEmpty)
        socket.emit(#"{"type":"end_session"}"#)
        XCTAssertEqual(fixture.client.currentStage, .closed)
        XCTAssertTrue(socket.controls.isEmpty)
        fixture.clock.releaseHolds()
        try await fixture.wait(core.done)
        try await fixture.wait(stopping.done)
        let result = await core.task.value
        XCTAssertEqual(result, "Kept.")
        await stopping.task.value
        XCTAssertTrue(socket.controls.isEmpty, "Retired claimed control cannot reach the transport")
        XCTAssertEqual(fixture.delegate.events, [
            .partial("Kept."), .boundary("Kept."), .partial("Kept."), .error
        ])
        // Failure republishes the same display to clear successful-final metadata.
        XCTAssertEqual(fixture.delegate.updates.map(\.text), ["Kept.", "Kept."])
        XCTAssertEqual(fixture.delegate.updates.map(\.isFinal), [true, false])
        XCTAssertEqual(fixture.delegate.errors.first as? GladiaStreamingError, .unexpectedSessionEnd)
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
    }

    func testConfiguredStopBeforeInitDrainsFramedAndPaddedPCMThenWaitsForEndSession() async throws {
        let fixture = try ConfiguredGladiaControllerFixture(heldSession: true)
        defer { fixture.cleanup() }
        try await fixture.start(open: false)
        XCTAssertEqual(fixture.sessions.pending, 1)
        XCTAssertTrue(fixture.transport.sockets.isEmpty)
        let input = Data(repeating: 7, count: 3_202)
        try fixture.admitPCM(input, complete: false)
        let stopping = fixture.ownStop(in: self)
        try await fixture.until("finish admitted while HTTP reply is held") { fixture.client.finishWaiterCount == 1 }
        XCTAssertEqual(fixture.client.admittedAudioBytes, 4_800)
        XCTAssertEqual(fixture.clock.count(fixture.grace), 0)
        XCTAssertTrue(fixture.transport.sockets.isEmpty)
        try fixture.sessions.grantNext()
        let socket = try XCTUnwrap(fixture.socket)
        socket.openAndBegin()
        XCTAssertEqual(socket.binary, [Data(input.prefix(3_200))])
        XCTAssertTrue(socket.controls.isEmpty)
        try socket.completeSend()
        XCTAssertEqual(socket.binary.map(\.count), [3_200, 1_600])
        XCTAssertEqual(socket.binary[1], Data(input.suffix(2)) + Data(repeating: 0, count: 1_598))
        XCTAssertEqual(fixture.clock.count(fixture.grace), 0)
        try socket.completeSend()
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 0)
        try await fixture.advanceGraceToControl()
        socket.emit(try frame("Opening and ending words.", id: "1", confidence: 0.85))
        XCTAssertFalse(stopping.settlement.settled)
        try await fixture.finish(stopping)
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["Opening and ending words."])
        XCTAssertEqual(fixture.delegate.results.first?.segments.map(\.text), ["Opening and ending words."])
        XCTAssertEqual(fixture.delegate.results.first?.confidence, 0.85)
        XCTAssertEqual(socket.controls, [ConfiguredGladiaControllerFixture.stopJSON])
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    private func frame(_ text: String, id: String, final: Bool = true, confidence: Double = 0.8) throws -> String {
        try GladiaControllerBoundaryFixture.frame(text, id: id, final: final, confidence: confidence)
    }
}
