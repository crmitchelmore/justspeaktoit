import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class ComparisonGladiaLaneTests: XCTestCase {
    func testHealthyConfiguredGladiaReleasesValidEndSessionAndReplacesDraftWithConfirmedWhole() async throws {
        let fixture = try Fixture()
        defer { fixture.lane.abandon() }
        try fixture.open()
        let socket = try XCTUnwrap(fixture.host.transport.sockets.last)
        socket.openAndBegin()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        try socket.completeSend()
        socket.emit(try GladiaControllerBoundaryFixture.frame("Yes.", id: "1"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("Yes.", id: "2"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("draft", id: "3", final: false))
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.lane.displayText, "Yes. Yes. draft")
        XCTAssertEqual(fixture.client.finalisationBudget, 4.5)
        let control = expectation(description: "comparison hands off owned Gladia stop")
        socket.observeSends { if $0 == .text(#"{"type":"stop_recording"}"#) { control.fulfill() } }
        let stopping = stop(fixture)
        try await wait(control)
        XCTAssertEqual(fixture.lane.displayText, "Yes. Yes. draft", "A held terminal has not yet replaced display")
        try socket.completeSend()
        socket.emit(#"{"type":"end_session"}"#)
        try await wait(stopping.done)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.lane.displayText, "Yes. Yes.", "Compare deliberately consumes raw confirmed whole")
        XCTAssertNil(fixture.lane.entry.errorDescription)
        XCTAssertNil(fixture.lane.client)
        XCTAssertEqual(socket.controls, [#"{"type":"stop_recording"}"#])
    }

    func testConfiguredGladiaCancellationCannotPublishLateOldTextIntoAnotherComparisonLane() async throws {
        let old = try Fixture(), next = try Fixture()
        defer { old.lane.abandon(); next.lane.abandon() }
        try old.open(); try next.open()
        let socket = try XCTUnwrap(old.host.transport.sockets.last)
        let replacement = try XCTUnwrap(next.host.transport.sockets.last)
        socket.openAndBegin(); replacement.openAndBegin()
        old.client.sendAudio(Data(repeating: 1, count: 3_200)); try socket.completeSend()
        socket.emit(try GladiaControllerBoundaryFixture.frame("Old.", id: "old"))
        replacement.emit(try GladiaControllerBoundaryFixture.frame("New.", id: "new"))
        old.updates.deliverAll(); next.updates.deliverAll()
        let lateReceive = try XCTUnwrap(socket.takeReceiver())
        let control = expectation(description: "old comparison finish owns its stop")
        socket.observeSends { if $0 == .text(#"{"type":"stop_recording"}"#) { control.fulfill() } }
        let stopping = stop(old)
        try await wait(control)
        stopping.task.cancel()
        try await wait(stopping.done)
        lateReceive(.success(.text(try GladiaControllerBoundaryFixture.frame("Stale.", id: "stale"))))
        old.updates.deliverAll(); next.updates.deliverAll()
        XCTAssertNotNil(old.lane.entry.errorDescription)
        XCTAssertNil(old.lane.client)
        XCTAssertEqual(next.lane.displayText, "New.")
        XCTAssertNil(next.lane.entry.errorDescription)
        XCTAssertEqual(replacement.cancels, 0)
    }

    private func stop(_ fixture: Fixture) -> (task: Task<Void, Never>, done: XCTestExpectation) {
        let done = XCTestExpectation(description: "Gladia comparison finish returned")
        let exited = XCTestExpectation(description: "owned Gladia comparison finish exited")
        let task = Task { @MainActor in
            defer { exited.fulfill() }
            await fixture.lane.finish(stoppedAt: Date())
            done.fulfill()
        }
        addTeardownBlock { @MainActor in
            task.cancel(); fixture.lane.abandon()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return (task, done)
    }
    private func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Configured comparison phase did not settle")
            throw AssemblyAIControllerFixture.Timeout()
        }
    }

    @MainActor
    private final class Fixture {
        let host = GladiaHostClientFixture()
        let updates = AssemblyAIControllerUpdates()
        let client: GladiaLiveClient
        let route: LiveTranscriptionRoute
        let lane: ComparisonLiveLane
        init() throws {
            route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming"))
            client = host.make()
            lane = ComparisonLiveLane(candidate: ComparisonCandidate(
                modelID: route.modelID, displayName: "Gladia fixture", providerDisplayName: "Gladia",
                engine: .sharedStreamingClient(route), supportsStreaming: true,
                supportsFile: false, unavailableReason: nil
            ))
            let client = client
            lane.clientFactory = { client }
        }
        func open() throws {
            let lane = lane, updates = updates
            try lane.openSharedClient(
                route: route, apiKey: "synthetic", language: nil, keywords: [], azureEndpoint: "",
                onTranscript: { [weak lane] text, final in
                    updates.enqueue { lane?.record(text: text, isFinal: final) }
                }
            )
        }
    }
}
