import Foundation
import XCTest
@testable import SpeakCore

/// Visible failures, prompt cancellation and per-run identity for the shared
/// Voxtral client over a fake transport.
final class MistralVoxtralFailureTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture
    private let budget = MistralVoxtralRealtime.finishBudget

    func testReadyAndSendDeadlinesFailVisiblyAndLateCompletionsAreIgnored() {
        let connecting = Fixture()
        connecting.start()
        connecting.socket.open()
        connecting.clock.fire(MistralVoxtralLiveClient.readyDeadline)
        XCTAssertEqual(connecting.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.sessionNotReady])
        XCTAssertEqual(connecting.socket.cancels, 1)

        let configuring = Fixture()
        configuring.start()
        configuring.socket.open()
        configuring.socket.sessionCreated()
        configuring.clock.fire(MistralVoxtralLiveClient.sendDeadline)
        guard case StreamingClientError.transportStalled? = configuring.events.errors.first else {
            return XCTFail("An update send that never completes is a stalled transport")
        }
        configuring.socket.completeSend()
        XCTAssertEqual(configuring.events.errors.count, 1, "A late completion cannot fail the run twice")

        let stalled = Fixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(Fixture.frame(0))
        stalled.clock.fire(MistralVoxtralLiveClient.sendDeadline)
        XCTAssertEqual(stalled.events.errors.count, 1)
        stalled.socket.completeSend()
        XCTAssertEqual(stalled.events.errors.count, 1)

        let ready = Fixture()
        ready.start()
        ready.becomeReady()
        ready.clock.fire(MistralVoxtralLiveClient.readyDeadline)
        XCTAssertTrue(ready.events.errors.isEmpty, "A configured session outlives the readiness deadline")
        ready.client.cancel()
    }

    func testRejectedHandshakesServerErrorsAndDroppedTransportsAreVisible() throws {
        let rejected = Fixture()
        rejected.start()
        rejected.socket.open()
        rejected.socket.mistralError("unauthorized", code: 401)
        XCTAssertEqual(
            rejected.events.errors.first as? MistralRealtimeError, .handshakeRejected(message: "unauthorized")
        )
        XCTAssertEqual(rejected.socket.cancels, 1)

        let server = Fixture()
        server.start()
        server.becomeReady()
        server.socket.mistralError("quota exhausted", code: 429)
        XCTAssertEqual(
            server.events.errors.first as? MistralRealtimeError, .server(message: "quota exhausted", code: 429)
        )

        let update = Fixture()
        update.start()
        update.socket.open()
        update.socket.sessionCreated()
        update.socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertEqual((update.events.errors.first as? URLError)?.code, .networkConnectionLost)
        XCTAssertFalse(update.client.isSessionReady)

        let dropped = Fixture()
        dropped.start()
        dropped.becomeReady()
        dropped.socket.fail()
        XCTAssertEqual((dropped.events.errors.first as? URLError)?.code, .networkConnectionLost)

        let upgrade = NSError(domain: "WinHTTP", code: 12_152,
                              userInfo: [NSLocalizedDescriptionKey: "WebSocket upgrade returned HTTP 401."])
        let mapped = dropped.client.mapConnectionError(upgrade)
        guard case StreamingClientError.invalidAPIKey(let provider)? = mapped as? StreamingClientError else {
            return XCTFail("A rejected upgrade is an invalid key")
        }
        XCTAssertEqual(provider, "Mistral")
    }

    func testFailedDrainFlushAndEndSendsStayFailuresWhenALateDoneArrives() async {
        let expected: [MistralRealtimeStreamingError?] = [nil, .missingCompletion, .missingCompletion]
        for step in 0..<3 {
            let fixture = Fixture()
            fixture.start()
            fixture.becomeReady()
            fixture.client.sendAudio(Fixture.frame(0))
            fixture.socket.delta("Heard")
            let finish = Task { await fixture.client.finishAndWait() }
            await fixture.waitForScheduled(budget)
            for _ in 0..<step { fixture.socket.completeSend() }
            fixture.socket.completeSend(URLError(.networkConnectionLost))
            // The receive registered before the failure still delivers a done.
            fixture.socket.done("Late and unconfirmed.")
            let transcript = await finish.value
            XCTAssertEqual(transcript, "Heard", "step \(step)")
            XCTAssertEqual(fixture.events.errors.count, 1, "step \(step)")
            let error = fixture.events.errors.first
            XCTAssertEqual(error as? MistralRealtimeStreamingError, expected[step], "step \(step)")
            if step == 0 { XCTAssertTrue(fixture.events.errors.first is URLError) }
            XCTAssertEqual(fixture.clock.pending(budget), 1, "The failure ended the finish before its deadline")
            let again = await fixture.client.finishAndWait()
            XCTAssertEqual(again, "Heard", "A done after an observed failure is never adopted: step \(step)")
        }
    }

    func testConcurrentFinishesShareOneOutcomeOneFlushAndOneDeadline() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        let client = fixture.client
        let first = Task { await client.finishAndWait() }
        let second = Task { await client.finishAndWait() }
        await fixture.settle { client.finishWaiterCount == 2 }
        for _ in 0..<3 { fixture.socket.completeSend() }
        fixture.socket.done("Shared.")
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Shared.", "Shared."])
        XCTAssertEqual(fixture.socket.types.filter { $0 == "input_audio.flush" }.count, 1)
        XCTAssertEqual(fixture.socket.types.filter { $0 == "input_audio.end" }.count, 1)
        XCTAssertEqual(fixture.clock.pending(budget), 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFailureIsPublishedBeforeFinishReturnsEvenWhenTheCallbackStartsAReplacement() async {
        let factory = AssemblyAISocketFactory()
        let clock = AssemblyAITestClock()
        let client = MistralVoxtralLiveClient(
            apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        let entered = expectation(description: "Error callback entered")
        let delivered = expectation(description: "Error delivered and replacement started")
        let premature = expectation(description: "Finish cannot return while error delivery is suspended")
        premature.isInverted = true
        let finished = expectation(description: "Finish returns after error delivery")
        let gate = MistralFailureGate()
        client.start(onTranscript: { _, _ in }, onError: { _ in
            entered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Old cleanup failed the replacement") })
            gate.markDelivered()
            delivered.fulfill()
        })
        let old = factory.sockets[0]
        Self.streamSavedText(on: old, into: client)
        let finish = Task {
            let result = await client.finishAndWait()
            if !gate.delivered { premature.fulfill() }
            finished.fulfill()
            return result
        }
        while client.finishWaiterCount == 0 { await Task.yield() }
        old.completeSend()
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [entered], timeout: 2)
        await fulfillment(of: [premature], timeout: 0.1)
        gate.release.signal()
        await fulfillment(of: [delivered, finished], timeout: 2)
        let result = await finish.value
        XCTAssertEqual(result, "Saved.")
        XCTAssertEqual(old.cancels, 1)
        assertReplacementStreams(factory, client)
    }
}

private extension MistralVoxtralFailureTests {
    /// Configures the session, admits one frame and hears one delta.
    static func streamSavedText(on socket: AssemblyAITestSocket, into client: MistralVoxtralLiveClient) {
        socket.open()
        socket.sessionCreated()
        socket.completeSend()
        client.sendAudio(Fixture.frame(0))
        socket.delta("Saved.")
    }

    /// The replacement started from the failure callback is untouched by the
    /// old run's cleanup and streams normally.
    func assertReplacementStreams(_ factory: AssemblyAISocketFactory, _ client: MistralVoxtralLiveClient) {
        XCTAssertEqual(factory.sockets.count, 2)
        let replacement = factory.sockets[1]
        replacement.open()
        replacement.sessionCreated()
        replacement.completeSend()
        client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(replacement.appendedAudio, [Fixture.frame(1)])
        client.cancel()
    }
}

private final class MistralFailureGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}
