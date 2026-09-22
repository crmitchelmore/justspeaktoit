import Foundation
import XCTest
@testable import SpeakCore

/// Stop sequencing for the shared Voxtral client: drain admitted audio, flush,
/// end, then `transcription.done`, all inside one whole deadline.
final class MistralVoxtralFinalisationTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture
    private let budget = MistralVoxtralRealtime.finishBudget

    func testFinishDrainsAdmittedAudioThenFlushesThenEndsAndDoneResolvesItAtOnce() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        let frames = (0..<3).map { Fixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        socket.delta("helo")
        socket.delta(" wrld")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        fixture.client.sendAudio(Fixture.frame(9))
        socket.completeSend()
        socket.completeSend()
        XCTAssertEqual(socket.types.last, "input_audio.append", "The flush waits for the last admitted frame")
        socket.completeSend()
        XCTAssertEqual(socket.types.last, "input_audio.flush")
        XCTAssertFalse(socket.types.contains("input_audio.end"), "The end waits for the flush to complete")
        socket.completeSend()
        XCTAssertEqual(
            socket.frameOrder, ["session.update", "input_audio.append", "input_audio.flush", "input_audio.end"]
        )
        socket.completeSend()
        socket.done("Hello world.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello world.", "The done text replaces the folded deltas")
        XCTAssertEqual(socket.appendedAudio, frames, "Audio offered after the finish began is not sent")
        XCTAssertEqual(fixture.events.texts, ["helo", "helo wrld"])
        XCTAssertEqual(fixture.events.finals, [false, false], "The consumed done is not also delivered as a final")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
        fixture.clock.fire(budget)
        XCTAssertTrue(fixture.events.errors.isEmpty, "Completion was event-driven; the spent deadline is inert")
    }

    func testAFinishDuringDelayedReadinessKeepsTheCaptureInsideOneWholeDeadline() async {
        let fixture = Fixture()
        fixture.start()
        let socket = fixture.socket
        let frames = (0..<2).map { Fixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        XCTAssertEqual(fixture.clock.pending(budget), 1, "One whole finish deadline, not one per phase")
        XCTAssertTrue(socket.controls.isEmpty, "Nothing leaves before the session is configured")
        socket.open()
        socket.sessionCreated()
        for _ in 0..<4 { socket.completeSend() }
        XCTAssertEqual(socket.types.last, "input_audio.end")
        // Early done: it arrives before the transport completes the end send.
        socket.done("Late but complete.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Late but complete.")
        XCTAssertEqual(socket.appendedAudio, frames)
        XCTAssertEqual(fixture.clock.pending(budget), 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testDoneAfterTheFlushLeftCompletesTheFinishWithoutTheEnd() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.types.last, "input_audio.flush")
        fixture.socket.done("Flushed.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Flushed.")
        XCTAssertFalse(fixture.socket.types.contains("input_audio.end"))
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAuthoritativeDoneReplacesPunctuatedAndShorterRevisions() async {
        let punctuated = await finished(deltas: ["hello", " world"], done: "Hello, world.")
        XCTAssertEqual(punctuated.transcript, "Hello, world.")
        let shorter = await finished(deltas: ["so I think that we should go now"], done: "Let's go.")
        XCTAssertEqual(shorter.transcript, "Let's go.", "No prefix or length heuristic keeps the longer draft")
        let kept = await finished(deltas: ["Kept draft"], done: "  ")
        XCTAssertEqual(kept.transcript, "Kept draft", "An empty done keeps the folded deltas")
        let silent = await finished(deltas: ["   "], done: "")
        XCTAssertNil(silent.transcript, "Silence stays empty; no placeholder text")
        for result in [punctuated, shorter, kept, silent] {
            XCTAssertTrue(result.events.errors.isEmpty)
            XCTAssertFalse(result.events.finals.contains(true))
        }
    }

    func testAFinishWithNoCapturedAudioIsEmptyAtOnceWithoutAFlush() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.socket.types, ["session.update"])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.clock.pending(budget), 0)
    }

    func testSynchronousTransportCompletesAWholeFinishWithoutNesting() async {
        let fixture = Fixture()
        fixture.start()
        let socket = fixture.socket
        let probe = MistralReentrancyProbe()
        socket.onSend = { [weak socket] _ in
            probe.enter()
            socket?.completeSend()
            probe.leave()
        }
        let frames = (0..<20).map { Fixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        socket.open()
        socket.sessionCreated()
        let finish = await fixture.finish(awaiting: "input_audio.end")
        socket.done("Synchronous.")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Synchronous.")
        XCTAssertEqual(socket.appendedAudio, frames)
        XCTAssertEqual(probe.maximumDepth, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testMissingDoneReportsFailureAndReturnsTheUnconfirmedDraftForRecovery() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.socket.delta("Everything I said")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        for _ in 0..<3 { fixture.socket.completeSend() }
        XCTAssertEqual(fixture.socket.types.last, "input_audio.end")
        fixture.clock.fire(budget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Everything I said")
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertFalse(fixture.events.finals.contains(true), "An unconfirmed draft is never labelled final")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testTheDeadlineNamesTheStepItCaught() async {
        let draining = Fixture()
        draining.start()
        draining.becomeReady()
        draining.client.sendAudio(Fixture.frame(0))
        let stalled = await expire(draining)
        guard case StreamingClientError.transportStalled? = stalled.first else {
            return XCTFail("An append that never completes is a stalled transport")
        }
        let connecting = Fixture()
        connecting.start()
        connecting.client.sendAudio(Fixture.frame(0))
        connecting.socket.open()
        let unready = await expire(connecting)
        XCTAssertEqual(unready.map { $0 as? MistralRealtimeStreamingError }, [.sessionNotReady])
        XCTAssertTrue(connecting.socket.controls.isEmpty)
    }

    func testSocketClosureAfterTheFlushWithoutDoneIsAMissingCompletion() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.socket.delta("Partial")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        for _ in 0..<3 { fixture.socket.completeSend() }
        fixture.socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Partial")
        XCTAssertEqual(fixture.events.errors.map { $0 as? MistralRealtimeStreamingError }, [.missingCompletion])
        XCTAssertEqual(fixture.clock.pending(budget), 1, "The closure ended the finish before its deadline")
    }

    // MARK: - Helpers

    private struct Outcome {
        let transcript: String?
        let events: AssemblyAITestEvents
    }

    private func finished(deltas: [String], done: String) async -> Outcome {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        deltas.forEach(fixture.socket.delta)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        for _ in 0..<3 { fixture.socket.completeSend() }
        fixture.socket.done(done)
        return Outcome(transcript: await finish.value, events: fixture.events)
    }

    /// Starts a finish, lets its whole deadline elapse and answers the errors.
    private func expire(_ fixture: Fixture) async -> [Error] {
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        fixture.clock.fire(budget)
        _ = await finish.value
        return fixture.events.errors
    }
}
