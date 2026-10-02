import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class AssemblyAICancellationTests: XCTestCase {
    func testDesktopCancellationUsesAbortOverrideInsteadOfGracefulStop() {
        let fixture = AssemblyAILiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        session.sendAudio(Data(repeating: 1, count: 3200))
        let cancelled = session.cancel()
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(socket.controls.isEmpty)
    }

    func testCancellationOfOldFinishCannotCloseReplacement() async {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let old = fixture.factory.sockets[0]
        old.open(); old.begin()
        let forcing = expectation(description: "A begun session's finish forces the endpoint")
        old.onSend = { if case .text(#"{"type":"ForceEndpoint"}"#) = $0 { forcing.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [forcing], timeout: 2)
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        finish.cancel()
        _ = await finish.value
        replacement.open(); replacement.begin()
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testFormattedTurnArrivingBeforeForceSendCompletionStillWaitsForCompletion() async {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await settle { socket.controls == [#"{"type":"ForceEndpoint"}"#] }
        socket.emit(#"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Done."}"#)
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        socket.completeSend()
        XCTAssertEqual(socket.controls.last, #"{"type":"Terminate"}"#)
        fixture.client.cancel()
        let text = await finish.value
        XCTAssertEqual(text, "Done.")
    }

    func testStopInsideTurnCallbackClosesAtOnceWithoutControlFrames() async {
        let fixture = AssemblyAILiveFixture()
        fixture.client.start(
            onTranscript: { [weak client = fixture.client] _, _ in client?.stop() }, onError: { _ in }
        )
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        socket.completeSend()
        socket.emit(
            #"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"transcript":"First."}"#
        )
        XCTAssertTrue(socket.controls.isEmpty, "stop() is immediate: no ForceEndpoint or Terminate")
        XCTAssertEqual(socket.cancels, 1)
        socket.emit(#"{"type":"Turn","turn_order":1,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Last."}"#)
        XCTAssertTrue(socket.controls.isEmpty)
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "First.", "The text received before the stop stays available")
    }

    func testFinishAfterBeginWithoutAudioStillForcesTheEndpointAndReturnsNil() async {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        let forcing = expectation(description: "A begun session's finish forces the endpoint")
        socket.onSend = { if case .text(#"{"type":"ForceEndpoint"}"#) = $0 { forcing.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [forcing], timeout: 2)
        XCTAssertTrue(socket.binary.isEmpty, "No fictitious audio is sent")
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        socket.completeSend()
        fixture.clock.fire(ModelCatalog.liveCapabilities(for: AssemblyAIModels.universal35ProStreamingID)
            .postStopFinalizeBudget)
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#, #"{"type":"Terminate"}"#])
        socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        let result = await finish.value
        XCTAssertNil(result)
    }

    func testFinishBeforeBeginPreservesOpeningAudioOnExistingConnection() async {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        let opening = Data(repeating: 42, count: 3200)
        fixture.client.sendAudio(opening)
        let finish = Task { await fixture.client.finishAndWait() }
        // The begin timeout and the finish deadline are both eight seconds.
        await settle { fixture.clock.pending(8) == 2 }
        XCTAssertTrue(socket.binary.isEmpty)
        socket.open(); socket.begin()
        XCTAssertEqual(socket.binary, [opening])
        socket.completeSend()
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        fixture.client.cancel()
        _ = await finish.value
    }

    func testStopBeforeBeginClosesAtOnceWithoutReconnecting() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data(repeating: 42, count: 3200))
        fixture.client.stop()
        XCTAssertEqual(socket.cancels, 1)
        socket.open(); socket.begin()
        XCTAssertTrue(socket.binary.isEmpty, "A stopped session sends nothing")
        XCTAssertTrue(socket.controls.isEmpty)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }
}
