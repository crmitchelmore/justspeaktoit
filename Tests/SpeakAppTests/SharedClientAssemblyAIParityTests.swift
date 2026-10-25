import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Synthetic transport through the actual shared client and Mac controller.
/// No microphone, credential lookup, provider request or production route changes.
@MainActor
final class SharedClientAssemblyAIParityTests: XCTestCase {
    func testStartupBoundariesPrecedeDisplayAndFinalSnapshotKeepsCorrectionsAndInterim() async throws {
        let fixture = try AssemblyAIControllerFixture()
        defer { fixture.client.cancel() }
        let transport = fixture.transport
        fixture.controller.startCaptureAudio = {
            let socket = try XCTUnwrap(transport.sockets.last)
            socket.openAndBegin()
            try socket.turn(0, text: "First.", utterance: "First.")
        }
        try await fixture.controller.start()
        let socket = try XCTUnwrap(fixture.sockets.last)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.events, [.boundary("First."), .partial("First.")])

        try socket.turn(1, text: "First.", utterance: "First.")
        try socket.turn(0, text: "Corrected.")
        try socket.turn(2, text: "pending words", final: false)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.boundaries, ["First.", "First."])
        XCTAssertEqual(fixture.delegate.partials.last, "Corrected. First. pending words")

        try await finish(fixture, socket: socket)
        fixture.updates.deliverAll()
        let result = try XCTUnwrap(fixture.delegate.results.first)
        XCTAssertEqual(fixture.delegate.results.count, 1)
        XCTAssertEqual(result.text, "Corrected. First. pending words")
        XCTAssertEqual(result.segments.map(\.text), ["Corrected.", "First."])
        XCTAssertTrue(result.segments.allSatisfy { $0.startTime == 0 && $0.endTime == 0 })
        XCTAssertEqual(result.modelIdentifier, AssemblyAIModels.universal36ProStreamingID)
        XCTAssertEqual(fixture.delegate.boundaries, ["First.", "First."], "No whole-history finish boundary")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testHeldPCMCompletesBeforeForceEndpointAndFinalBeforeTerminate() async throws {
        let fixture = try AssemblyAIControllerFixture()
        defer { fixture.client.cancel() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.last)
        let pcm = Data((0..<3_200).map { UInt8($0 % 251) })
        fixture.client.sendAudio(pcm)
        XCTAssertEqual(socket.binary, [pcm])
        let armed = expectation(description: "finish deadline armed behind held PCM")
        fixture.clock.observeSchedule { seconds in if seconds == 8 { armed.fulfill() } }
        let stopping = ownedStop(fixture)
        defer { stopping.task.cancel(); fixture.client.cancel() }
        try await wait(armed)
        XCTAssertTrue(socket.controls.isEmpty)
        XCTAssertTrue(fixture.delegate.results.isEmpty)

        try socket.completeSend()
        XCTAssertEqual(socket.controls, [AssemblyAIControllerFixture.force])
        try socket.completeSend()
        try socket.turn(0, text: "Tail.", utterance: "Tail.")
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.boundaries, ["Tail."])
        XCTAssertEqual(socket.controls, [AssemblyAIControllerFixture.force, AssemblyAIControllerFixture.terminate])
        try socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        try await join(stopping, fixture: fixture)
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["Tail."])
        XCTAssertEqual(socket.binary, [pcm])
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testCancelledFinishAndOldQueuedEventsCannotAffectReplacement() async throws {
        let fixture = try AssemblyAIControllerFixture()
        defer { fixture.client.cancel() }
        try await fixture.start()
        let old = try XCTUnwrap(fixture.sockets.last)
        try old.turn(0, text: "Old.", utterance: "Old.")
        let lateReceive = try XCTUnwrap(old.takeReceiver())
        let forcing = expectation(description: "old finish reached ForceEndpoint")
        old.observeSends { if $0 == .text(AssemblyAIControllerFixture.force) { forcing.fulfill() } }
        let stopping = ownedStop(fixture)
        defer { stopping.task.cancel(); fixture.client.cancel() }
        try await wait(forcing)
        stopping.task.cancel()
        try await join(stopping, fixture: fixture)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
        let oldDeadlines = fixture.clock.takeActions()
        let previousBoundaries = fixture.delegate.boundaries

        try await fixture.start()
        let replacement = try XCTUnwrap(fixture.sockets.last)
        try replacement.turn(0, text: "Replacement.", utterance: "Replacement.")
        lateReceive(.success(.text(try AssemblyAIControllerSocket.turn(9, text: "Stale.", utterance: "Stale."))))
        try old.completeSend(URLError(.networkConnectionLost))
        oldDeadlines.forEach { $0() }
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.boundaries, previousBoundaries + ["Replacement."])
        XCTAssertEqual(fixture.delegate.partials.last, "Replacement.")
        XCTAssertFalse(fixture.delegate.partials.contains("Stale."))
        XCTAssertEqual(replacement.cancels, 0)
        try await finish(fixture, socket: replacement)
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["Replacement."])
        XCTAssertEqual(fixture.delegate.errors.count, 1)
    }

    func testEmptySessionDoesNotInventPCMTextOrBoundaries() async throws {
        let fixture = try AssemblyAIControllerFixture()
        defer { fixture.client.cancel() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.last)
        try await finish(fixture, socket: socket)
        XCTAssertTrue(socket.binary.isEmpty)
        XCTAssertEqual(fixture.delegate.results.map(\.text), [""])
        XCTAssertTrue(fixture.delegate.results.first?.segments.isEmpty == true)
        XCTAssertTrue(fixture.delegate.boundaries.isEmpty)
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testTransportFailureDuringFinishPreservesDraftWithoutTerminalSuccess() async throws {
        let fixture = try AssemblyAIControllerFixture()
        defer { fixture.client.cancel() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.last)
        try socket.turn(0, text: "Unconfirmed draft", final: false)
        let forcing = expectation(description: "finish reached ForceEndpoint")
        socket.observeSends { if $0 == .text(AssemblyAIControllerFixture.force) { forcing.fulfill() } }
        let stopping = ownedStop(fixture)
        defer { stopping.task.cancel(); fixture.client.cancel() }
        try await wait(forcing)
        socket.fail()
        try await join(stopping, fixture: fixture)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.partials.last, "Unconfirmed draft")
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertTrue(fixture.delegate.boundaries.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    private func finish(_ fixture: AssemblyAIControllerFixture, socket: AssemblyAIControllerSocket) async throws {
        let forcing = expectation(description: "ForceEndpoint admitted")
        socket.observeSends { if $0 == .text(AssemblyAIControllerFixture.force) { forcing.fulfill() } }
        let stopping = ownedStop(fixture)
        defer { stopping.task.cancel(); fixture.client.cancel() }
        try await wait(forcing)
        try socket.completeSend()
        XCTAssertEqual(fixture.clock.fire(2), 1, "Selected model's finalization budget")
        XCTAssertEqual(socket.controls.last, AssemblyAIControllerFixture.terminate)
        try socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        try await join(stopping, fixture: fixture)
    }

    private func wait(_ signal: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
        guard result == .completed else {
            XCTFail("Owned provider/controller stage did not complete: \(signal.expectationDescription)")
            throw AssemblyAIControllerFixture.Timeout()
        }
    }

    private func ownedStop(_ fixture: AssemblyAIControllerFixture) -> AssemblyAIControllerFixture.Stopping {
        let stopping = fixture.stop()
        addTeardownBlock { @MainActor in
            stopping.task.cancel()
            fixture.client.cancel()
            let result = await XCTWaiter.fulfillment(of: [stopping.cleanedUp], timeout: 2)
            XCTAssertEqual(result, .completed, "Owned stop task must exit after every success or failed stage")
        }
        return stopping
    }

    private func join(
        _ stopping: AssemblyAIControllerFixture.Stopping, fixture: AssemblyAIControllerFixture
    ) async throws {
        do { try await wait(stopping.done) } catch {
            stopping.task.cancel()
            fixture.client.cancel()
            throw error
        }
    }
}
