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
        let terminating = expectation(description: "No-audio finish sends Terminate")
        old.onSend = { if case .text = $0 { terminating.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [terminating], timeout: 2)
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

    func testFormattedTurnArrivingBeforeForceSendCompletionStillWaitsForCompletion() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        socket.completeSend()
        fixture.client.stop()
        socket.emit(#"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Done."}"#)
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        socket.completeSend()
        XCTAssertEqual(socket.controls.last, #"{"type":"Terminate"}"#)
        fixture.client.cancel()
    }

    func testStoppingInsideTurnCallbackDoesNotTreatThatOldTurnAsForceEndpointResponse() {
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
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        socket.completeSend()
        XCTAssertEqual(socket.controls.count, 1)
        socket.emit(#"{"type":"Turn","turn_order":1,"turn_is_formatted":true,"end_of_turn":true,"transcript":"Last."}"#)
        XCTAssertEqual(socket.controls.last, #"{"type":"Terminate"}"#)
        fixture.client.cancel()
    }

    func testEmptyFinishSendsNoPCMOrForceEndpointAndReturnsNil() async {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open(); socket.begin()
        let terminating = expectation(description: "Empty session terminates directly")
        socket.onSend = { if case .text = $0 { terminating.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [terminating], timeout: 2)
        XCTAssertTrue(socket.binary.isEmpty)
        XCTAssertEqual(socket.controls, [#"{"type":"Terminate"}"#])
        socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        let result = await finish.value
        XCTAssertNil(result)
    }

    func testStopBeforeBeginPreservesOpeningAudioOnExistingConnection() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        let opening = Data(repeating: 42, count: 3200)
        fixture.client.sendAudio(opening)
        fixture.client.stop()
        XCTAssertTrue(socket.binary.isEmpty)
        socket.open(); socket.begin()
        XCTAssertEqual(socket.binary, [opening])
        socket.completeSend()
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        fixture.client.cancel()
    }
}
