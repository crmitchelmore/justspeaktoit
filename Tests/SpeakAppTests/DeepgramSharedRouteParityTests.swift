import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The former `DeepgramLiveController` behaviour, proven on the shared path.
@MainActor
final class DeepgramSharedRouteParityTests: XCTestCase {
    func testNovaFinishDrainsPCMAndIncludesEveryTrailingFinalOnce() async throws {
        try await assertTrailingFinals(model: "deepgram/nova-3-streaming")
    }

    func testFluxFinishDrainsPCMAndIncludesEveryTrailingTurnOnce() async throws {
        try await assertTrailingFinals(model: "deepgram/flux-general-en-streaming")
    }

    func testMidSessionFailureKeepsTheVisibleDraftAndReportsOnce() async throws {
        let fixture = try makeFixture(model: "deepgram/nova-3-streaming")
        try await fixture.start()
        fixture.socket.emit(Self.event("Confirmed.", final: true, model: "nova-3"))
        fixture.socket.emit(Self.event("draft", final: false, model: "nova-3"))
        fixture.socket.fail()
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertEqual(fixture.delegate.partials.last, "Confirmed. draft")

        await fixture.controller.stop()
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1, "The failure is reported exactly once")
        XCTAssertTrue(fixture.delegate.results.isEmpty, "A failed stream must not publish terminal success")
        XCTAssertEqual(fixture.delegate.partials.last, "Confirmed. draft")
    }

    func testUserStopGraceWaitsBeforeCloseStreamAndExtendsTheWatchdog() async throws {
        let fixture = try makeFixture(model: "deepgram/nova-3-streaming", grace: 0.2)
        try await fixture.start()
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 10.2, accuracy: 0.001)
        let began = Date()
        let socket = fixture.socket
        let stopping = await fixture.beginStop { socket.text == [#"{"type":"CloseStream"}"#] }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.2, "Grace precedes CloseStream")
        socket.completeSends()
        socket.emit(#"{"type":"Metadata"}"#)
        await stopping.value
        XCTAssertEqual(fixture.delegate.results.last?.text, "")
    }

    private func assertTrailingFinals(model: String) async throws {
        let fixture = try makeFixture(model: model)
        let apiModel = try XCTUnwrap(LiveTranscriptionRouting.route(for: model)).apiModelName
        try await fixture.start()
        fixture.socket.emit(Self.event("Yes.", final: true, model: apiModel))
        fixture.socket.emit(Self.event("Yes.", final: true, model: apiModel))
        fixture.updates.deliverAll()
        fixture.send(Data([1, 0]))
        fixture.send(Data([2, 0]))
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [#"{"type":"CloseStream"}"#]
        }
        XCTAssertEqual(socket.binary, [Data([1, 0]), Data([2, 0])], "PCM drains before CloseStream")
        socket.completeSends()
        socket.emit(Self.event("Tail one.", final: true, model: apiModel))
        socket.emit(Self.event("Tail two.", final: true, model: apiModel))
        if apiModel.hasPrefix("flux-") { socket.fail() } else { socket.emit(#"{"type":"Metadata"}"#) }
        await stopping.value
        fixture.updates.deliverAll()

        let result = try XCTUnwrap(fixture.delegate.results.last)
        XCTAssertEqual(result.text, "Yes. Yes. Tail one. Tail two.", "Standalone repeats stay distinct")
        XCTAssertEqual(result.modelIdentifier, model)
        XCTAssertEqual(
            result.cost?.totalCost,
            TranscriptionPricing.estimatedCostUSD(modelID: model, durationSeconds: result.duration),
            "History keeps a Deepgram cost estimate"
        )
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
    }

    private func makeFixture(model: String, grace: TimeInterval = 0) throws -> SharedClientParityFixture {
        try SharedClientParityFixture(model: model, stopGrace: grace) { route, _, socket, clock in
            DeepgramLiveClient(
                apiKey: "synthetic", model: route.apiModelName, sampleRate: route.sampleRate,
                makeConnection: { _ in socket }, schedule: { clock.schedule($0, action: $1) }
            )
        }
    }

    private static func event(_ text: String, final: Bool, model: String) -> String {
        if model.hasPrefix("flux-") {
            return #"{"type":"TurnInfo","event":""# + (final ? "EndOfTurn" : "Update")
                + #"","transcript":""# + text + #""}"#
        }
        return #"{"is_final":"# + String(final)
            + #", "channel":{"alternatives":[{"transcript":""# + text + #""}]}}"#
    }
}
