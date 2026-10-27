#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class GladiaFactoryProjectionTests: XCTestCase {
    func testActualIOSFactoryConstructionSelectsConfiguredDefaultWithoutStartingNetwork() throws {
        let transcriber = try makeTranscriber()
        // This is the exact helper production start calls with clientFactory=nil.
        // It constructs, but never starts, the actual public-factory client.
        let client = try XCTUnwrap(transcriber.makeClient() as? GladiaLiveClient)
        XCTAssertEqual(client.finalisationBudget, 4.5)
        XCTAssertEqual(transcriber.stopCompletionTimeout, 10)
    }

    func testActualConfiguredClientKeepsIOSConfirmedWholeProjectionAndExistingWatchdog() async throws {
        let transcriber = try makeTranscriber()
        let socket = OverflowTestSocket()
        let client = GladiaLiveClient(
            apiKey: "synthetic", options: LiveClientOptions(),
            initiateSession: { _, completion in
                completion(.success((201, Data(#"{"url":"wss://api.gladia.io/v2/live?token=synthetic"}"#.utf8))))
                return GladiaIOSSessionRequest()
            }, makeConnection: { _ in socket }
        )
        // This lifecycle fixture injects the actual configured client, bypassing
        // the factory/credentials/capture. Pure production-factory proof is above.
        transcriber.clientFactory = { client }
        transcriber.startCaptureAudio = {}
        try await transcriber.start()
        defer { transcriber.cancel() }
        addTeardownBlock { @MainActor in
            transcriber.cancel()
            await transcriber.awaitCancellationSettled()
        }
        XCTAssertEqual(transcriber.stopCompletionTimeout, 10)
        client.sendAudio(Data(repeating: 1, count: 3_200))
        let draft = expectation(description: "iOS receives configured raw standalone events")
        transcriber.onPartialResult = { text, _ in if text == "Yes. Yes. draft" { draft.fulfill() } }
        emit(socket, text: "Yes.", id: "1", final: true)
        emit(socket, text: "Yes.", id: "2", final: true)
        emit(socket, text: "draft", id: "3", final: false)
        await fulfillment(of: [draft], timeout: 2)
        transcriber.onPartialResult = nil
        let stopping = ownedStop(transcriber)
        let stop = stopping.task
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !socket.types.contains("stop_recording"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard socket.types.contains("stop_recording") else {
            stop.cancel(); transcriber.cancel()
            XCTFail("Configured stop did not reach its synthetic socket")
            throw GladiaIOSFixtureTimeout()
        }
        socket.emit(["type": "end_session"])
        guard await XCTWaiter.fulfillment(of: [stopping.done], timeout: 2) == .completed else {
            stop.cancel(); transcriber.cancel()
            XCTFail("Configured iOS stop did not settle")
            throw GladiaIOSFixtureTimeout()
        }
        let result = await stop.value
        assertIOSResult(result)
        XCTAssertNil(transcriber.error)
        XCTAssertEqual(socket.types.filter { $0 == "stop_recording" }.count, 1)
    }

    private func assertIOSResult(_ result: TranscriptionResult) {
        XCTAssertEqual(result.text, "Yes. Yes.", "iOS retains raw confirmed-whole finish semantics")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.confidence)
        XCTAssertNil(result.cost)
    }

    private struct Stop {
        let task: Task<TranscriptionResult, Never>
        let done: XCTestExpectation
    }
    private func ownedStop(_ transcriber: SharedClientLiveTranscriber) -> Stop {
        let done = XCTestExpectation(description: "iOS configured stop returned")
        let exited = XCTestExpectation(description: "owned iOS configured stop exited")
        let stop = Task { @MainActor in
            defer { exited.fulfill() }
            let result = await transcriber.stop()
            done.fulfill()
            return result
        }
        addTeardownBlock { @MainActor in
            stop.cancel(); transcriber.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Stop(task: stop, done: done)
    }

    private func makeTranscriber() throws -> SharedClientLiveTranscriber {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "gladia/solaria-1-streaming"))
        return SharedClientLiveTranscriber(route: route, apiKey: "synthetic", audioSessionManager: manager)
    }
    private func emit(_ socket: OverflowTestSocket, text: String, id: String, final: Bool) {
        socket.emit(["type": "transcript", "data": [
            "id": id, "is_final": final, "utterance": ["text": text]
        ]])
    }
}
private final class GladiaIOSSessionRequest: GladiaLiveSessionRequest { func cancel() {} }
private struct GladiaIOSFixtureTimeout: Error {}
#endif
