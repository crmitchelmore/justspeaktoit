import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The former `CartesiaLiveController` behaviour, proven on the shared path.
@MainActor
final class CartesiaSharedRouteParityTests: XCTestCase {
    func testPCMDrainsBeforeCloseThenLateTurnsAndDraftReplaceTheWholeResultOnce() async throws {
        let fixture = try makeFixture()
        try await fixture.start()
        fixture.socket.emit(Self.turn("First.", final: true))
        fixture.updates.deliverAll()
        fixture.send(Data(repeating: 1, count: 4_200))
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [#"{"type":"close"}"#]
        }
        XCTAssertEqual(socket.binary.map(\.count), [3_200, 1_600], "Core frames 100 ms and pads the residual")
        socket.completeSends()
        socket.emit(Self.turn("Late.", final: true))
        socket.emit(Self.turn("open draft", final: false))
        socket.fail(CartesiaParityPeerClose())
        await stopping.value

        let result = try XCTUnwrap(fixture.delegate.results.last)
        XCTAssertEqual(result.text, "First. Late. open draft")
        XCTAssertEqual(result.segments.map(\.text), ["First.", "Late."], "History keeps the rich turn segments")
        XCTAssertEqual(result.modelIdentifier, "cartesia/ink-2-streaming")
        XCTAssertEqual(fixture.delegate.partials.last, "First. Late. open draft")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 10, "Run retired")
    }

    func testFinishFailureKeepsTrailingTurnAndDraftAndNeverReportsSuccess() async throws {
        let fixture = try makeFixture()
        try await fixture.start()
        fixture.socket.emit(Self.turn("Confirmed.", final: true))
        let socket = fixture.socket
        let stopping = await fixture.beginStop { socket.text == [#"{"type":"close"}"#] }
        socket.emit(Self.turn("New tail.", final: true))
        socket.emit(Self.turn("retained draft", final: false))
        socket.completeSends(error: URLError(.networkConnectionLost))
        await stopping.value
        fixture.updates.deliverAll()

        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty, "A failed stream must not publish terminal success")
        XCTAssertEqual(fixture.delegate.partials.last, "Confirmed. New tail. retained draft")
    }

    func testSilentFinishPublishesAnEmptyResult() async throws {
        let fixture = try makeFixture()
        try await fixture.start()
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [#"{"type":"close"}"#]
        }
        socket.completeSends()
        socket.fail(CartesiaParityPeerClose())
        await stopping.value
        XCTAssertEqual(fixture.delegate.results.last?.text, "")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testStopGraceAndBudgetStayInsideTheClientAndTheWatchdogOutlivesThem() async throws {
        let fixture = try makeFixture(grace: 0.3)
        try await fixture.start()
        let budget = try XCTUnwrap((fixture.client as? FinalizingStreamingTranscriptionClient)?.finalisationBudget)
        XCTAssertEqual(
            fixture.controller.stopCompletionTimeout, max(10, budget + 1),
            "Cartesia's grace is folded into its own budget, so the host adds nothing"
        )
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text == [#"{"type":"close"}"#]
        }
        socket.completeSends()
        socket.fail(CartesiaParityPeerClose())
        await stopping.value
    }

    private func makeFixture(grace: TimeInterval = 0) throws -> SharedClientParityFixture {
        try SharedClientParityFixture(
            model: "cartesia/ink-2-streaming", stopGrace: grace
        ) { route, options, socket, clock in
            CartesiaLiveClient(
                apiKey: "synthetic", model: route.apiModelName, sampleRate: route.sampleRate,
                postStopFinalizeBudget: options.postStopFinalizeBudget ?? 1.5,
                stopGracePeriod: options.stopGracePeriod,
                makeConnection: { _ in socket }, schedule: { clock.schedule($0, action: $1) }
            )
        }
    }

    private static func turn(_ text: String, final: Bool) -> String {
        #"{"type":"turn."# + (final ? "end" : "update") + #"","transcript":""# + text + #""}"#
    }
}

private struct CartesiaParityPeerClose: StreamingWebSocketCloseReporting { let webSocketCloseCode: Int? = 1000 }
