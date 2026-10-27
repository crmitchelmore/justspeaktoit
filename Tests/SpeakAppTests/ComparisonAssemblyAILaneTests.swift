import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class ComparisonAssemblyAILaneTests: XCTestCase {
    func testFinishReplacesCumulativeDisplayWithTheCompleteSessionExactlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.lane.abandon() }
        try fixture.open()
        let socket = try XCTUnwrap(fixture.transport.sockets.last)
        socket.openAndBegin()
        try socket.turn(0, text: "First.")
        try socket.turn(1, text: "draft", final: false)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.lane.displayText, "First. draft")
        XCTAssertEqual(fixture.lane.sampleRate, 16_000)

        let forcing = expectation(description: "comparison finish reached ForceEndpoint")
        socket.observeSends { if $0 == .text(#"{"type":"ForceEndpoint"}"#) { forcing.fulfill() } }
        let stopping = stop(fixture)
        try await wait(forcing)
        try socket.completeSend()
        try socket.turn(1, text: "Tail.")
        XCTAssertEqual(socket.controls.last, #"{"type":"Terminate"}"#)
        try socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        try await wait(stopping.done)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.lane.displayText, "First. Tail.")
        XCTAssertNil(fixture.lane.entry.errorDescription)
        XCTAssertNil(fixture.lane.client)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testCancelledFinishClosesItsClientAndCannotReplaceAnotherLane() async throws {
        let old = try Fixture()
        let replacement = try Fixture()
        defer { old.lane.abandon(); replacement.lane.abandon() }
        try old.open()
        try replacement.open()
        let oldSocket = try XCTUnwrap(old.transport.sockets.last)
        let replacementSocket = try XCTUnwrap(replacement.transport.sockets.last)
        oldSocket.openAndBegin()
        replacementSocket.openAndBegin()
        try oldSocket.turn(0, text: "Old.")
        try replacementSocket.turn(0, text: "Replacement.")
        old.updates.deliverAll()
        replacement.updates.deliverAll()
        let lateReceive = try XCTUnwrap(oldSocket.takeReceiver())
        let forcing = expectation(description: "owned comparison finish waiting for final")
        oldSocket.observeSends { if $0 == .text(#"{"type":"ForceEndpoint"}"#) { forcing.fulfill() } }
        let stopping = stop(old)
        try await wait(forcing)
        stopping.task.cancel()
        try await wait(stopping.done)
        lateReceive(.success(.text(try AssemblyAIControllerSocket.turn(1, text: "Stale."))))
        old.updates.deliverAll()
        replacement.updates.deliverAll()
        XCTAssertNotNil(old.lane.entry.errorDescription)
        XCTAssertNil(old.lane.client)
        XCTAssertEqual(oldSocket.cancels, 1)
        XCTAssertEqual(replacementSocket.cancels, 0)
        XCTAssertEqual(replacement.lane.displayText, "Replacement.")
        XCTAssertNil(replacement.lane.entry.errorDescription)
    }

    private func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned comparison stage did not complete: \(signal.expectationDescription)")
            throw AssemblyAIControllerFixture.Timeout()
        }
    }

    private func stop(_ fixture: Fixture) -> (task: Task<Void, Never>, done: XCTestExpectation) {
        let done = expectation(description: "comparison finish returned")
        let cleanedUp = XCTestExpectation(description: "owned comparison finish exited")
        let task = Task { @MainActor in
            defer { cleanedUp.fulfill() }
            await fixture.lane.finish(stoppedAt: Date())
            done.fulfill()
        }
        addTeardownBlock { @MainActor in
            task.cancel()
            fixture.lane.abandon()
            let result = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(result, .completed, "Every admitted comparison finish must unwind")
        }
        return (task, done)
    }

    @MainActor
    private final class Fixture {
        let transport = AssemblyAIControllerTransport()
        let clock = AssemblyAIControllerClock()
        let updates = AssemblyAIControllerUpdates()
        let route: LiveTranscriptionRoute
        let client: AssemblyAILiveClient
        let lane: ComparisonLiveLane

        init() throws {
            route = try XCTUnwrap(LiveTranscriptionRouting.route(for: AssemblyAIModels.universal36ProStreamingID))
            let transport = transport, clock = clock
            client = AssemblyAILiveClient(
                apiKey: "synthetic-unused-key", makeConnection: { transport.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
            lane = ComparisonLiveLane(candidate: ComparisonCandidate(
                modelID: route.modelID, displayName: "AssemblyAI fixture", providerDisplayName: "AssemblyAI",
                engine: .sharedStreamingClient(route), supportsStreaming: true, supportsFile: false,
                unavailableReason: nil
            ))
            let client = client
            lane.clientFactory = { client }
        }

        func open() throws {
            let lane = lane, updates = updates
            try lane.openSharedClient(
                route: route, apiKey: "synthetic-unused-key", language: nil, keywords: [], azureEndpoint: "",
                onTranscript: { [weak lane] text, final in
                    updates.enqueue { lane?.record(text: text, isFinal: final) }
                }
            )
        }
    }
}
