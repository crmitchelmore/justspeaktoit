import Foundation
import XCTest
@testable import SpeakCore

/// When `transcription.done` completes a session. Mistral's SDK stops reading
/// at done and cancels its pending sender, so a done may supersede a flush or
/// end whose send has not completed. This client also requires every admitted
/// append to have completed first, so a done never stands for audio the
/// service might not have received, and an early done is never adopted.
final class MistralVoxtralCompletionTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture
    private let budget = MistralVoxtralRealtime.finishBudget

    func testDoneWhileAnAdmittedAppendIsInFlightFailsAndKeepsTheVisibleDraft() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.socket.delta("so I think that we should go now")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        XCTAssertEqual(fixture.socket.types.last, "input_audio.append", "The admitted frame is still in flight")
        fixture.socket.done("Let's go.")
        let transcript = await finish.value
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.unexpectedCompletion])
        XCTAssertEqual(transcript, "so I think that we should go now", "An early done is not adopted as confirmed")
        XCTAssertFalse(fixture.socket.types.contains("input_audio.flush"))
        XCTAssertFalse(fixture.events.finals.contains(true))
    }

    func testDoneWhileAdmittedAppendsAreQueuedFailsAndSendsNothingMore() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        (0..<3).forEach { fixture.client.sendAudio(Fixture.frame($0)) }
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 2, "One frame in flight, one still queued")
        fixture.socket.done("Early.")
        let transcript = await finish.value
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.unexpectedCompletion])
        XCTAssertEqual(transcript, "Early.", "With no visible draft, the early done's text is the only recovery text")
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.appendedAudio, [Fixture.frame(0), Fixture.frame(1)])
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testUnsolicitedDoneWhileStreamingFailsAndKeepsTheVisibleDraft() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.socket.completeSend()
        fixture.socket.delta("Cut")
        fixture.socket.done("Cut short.")
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.unexpectedCompletion])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertFalse(fixture.events.finals.contains(true))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Cut", "A finish after the failure returns the visible draft at once")
    }

    func testACancellationCompletionAfterAValidDoneIsInert() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.types.last, "input_audio.end", "The end is still in flight")
        fixture.socket.done("Complete.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Complete.")
        XCTAssertEqual(fixture.socket.cancels, 1)
        // Cancelling the socket fails its pending send, as WinHTTP reports it.
        fixture.socket.completeSend(CancellationError())
        fixture.clock.drain().forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let again = await fixture.client.finishAndWait()
        XCTAssertEqual(again, "Complete.")
    }

    func testAFinishWhileTheTransportFactoryIsRunningKeepsTheStartedRun() async {
        let factory = AssemblyAISocketFactory()
        let clock = AssemblyAITestClock()
        let events = AssemblyAITestEvents()
        let gate = MistralFactoryGate()
        let client = MistralVoxtralLiveClient(apiKey: "synthetic", makeConnection: { request in
            gate.enterAndWait()
            return factory.make(request)
        }, schedule: { clock.schedule($0, action: $1) })
        let started = expectation(description: "start returned once the factory did")
        DispatchQueue.global().async {
            client.start(onTranscript: { events.transcript($0, final: $1) }, onError: { events.fail($0) })
            started.fulfill()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        client.sendAudio(Fixture.frame(0))
        XCTAssertEqual(client.bufferedAudioFrames, 1, "The started run admits audio before its socket exists")
        let finish = Task { await client.finishAndWait() }
        for _ in 0..<400 {
            if clock.pending(budget) > 0 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(clock.pending(budget), 1, "The finish armed its one whole deadline")
        XCTAssertEqual(client.finishWaiterCount, 1, "The finish waits for the started run instead of closing it")
        gate.release.signal()
        await fulfillment(of: [started], timeout: 2)
        let socket = factory.sockets[0]
        socket.open()
        socket.sessionCreated()
        for _ in 0..<3 { socket.completeSend() }
        XCTAssertEqual(socket.appendedAudio, [Fixture.frame(0)])
        socket.done("Kept.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertTrue(events.errors.isEmpty)
    }
}

/// Holds an injected transport factory open until the test releases it.
private final class MistralFactoryGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func enterAndWait() {
        entered.signal()
        release.wait()
    }
}
