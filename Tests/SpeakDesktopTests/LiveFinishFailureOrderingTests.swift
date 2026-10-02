import Foundation
import XCTest
import SpeakCore

final class LiveFinishFailureOrderingTests: XCTestCase {
    func testAssemblyAIFailureIsDeliveredBeforeFinishReturnsAndMayStartReplacement() async {
        await exerciseFailureOrdering(assemblyAI: true)
    }

    func testDeepgramFailureIsDeliveredBeforeFinishReturnsAndMayStartReplacement() async {
        await exerciseFailureOrdering(assemblyAI: false)
    }

    private func exerciseFailureOrdering(assemblyAI: Bool) async {
        let factory = AssemblyAISocketFactory()
        let client = makeClient(assemblyAI: assemblyAI, factory: factory)
        let errorEntered = expectation(description: "Error callback entered on provider queue")
        let errorCompleted = expectation(description: "Error callback delivered and replacement started")
        let prematurelyReturned = expectation(description: "Finish cannot return while error delivery is suspended")
        prematurelyReturned.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = FinishFailureGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            errorEntered.fulfill()
            // This runs on the provider queue, never MainActor. Hold delivery
            // open while the test lets the finish waiter execute elsewhere.
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Replacement was failed by old cleanup") })
            gate.markDelivered()
            errorCompleted.fulfill()
        })
        let old = factory.sockets[0]
        openWithSavedTranscript(old, assemblyAI: assemblyAI)
        let finishing = expectation(description: "Control send proves finish waiter is registered")
        old.onSend = { if case .text = $0 { finishing.fulfill() } }
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { prematurelyReturned.fulfill() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finishing], timeout: 2)
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [errorEntered], timeout: 2)
        await fulfillment(of: [prematurelyReturned], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [errorCompleted, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(factory.sockets.count, 2)
        let replacement = factory.sockets[1]
        replacement.open()
        if assemblyAI { replacement.begin() }
        client.sendAudio(Data(repeating: 0, count: 3200))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.binary.count, 1)
        client.cancel()
    }

    private func makeClient(
        assemblyAI: Bool, factory: AssemblyAISocketFactory
    ) -> any FinalizingStreamingTranscriptionClient {
        let clock = AssemblyAITestClock()
        if assemblyAI {
            return AssemblyAILiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        } else {
            return DeepgramLiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        }
    }

    private func openWithSavedTranscript(_ socket: AssemblyAITestSocket, assemblyAI: Bool) {
        socket.open()
        if assemblyAI {
            socket.begin()
            let turn = #"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":true,"#
                + #""transcript":"Saved."}"#
            socket.emit(turn)
        } else {
            socket.emit(#"{"is_final":true,"channel":{"alternatives":[{"transcript":"Saved."}]}}"#)
        }
    }

}

private final class FinishFailureGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
