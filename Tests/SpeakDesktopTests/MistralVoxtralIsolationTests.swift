import Foundation
import XCTest
@testable import SpeakCore

/// Per-run identity, prompt cancellation at every phase, tolerant parsing and
/// the established socket-free seams of the shared Voxtral client.
final class MistralVoxtralIsolationTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture
    private let budget = MistralVoxtralRealtime.finishBudget

    func testOldSocketCallbacksAndDeadlinesCannotTouchTheReplacementRun() {
        let fixture = Fixture()
        fixture.start()
        let old = fixture.socket
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        old.delta("Stale")
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        old.open()
        old.done("Stale done.")
        old.completeSend(URLError(.networkConnectionLost))
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.events.texts, ["Stale"])
        XCTAssertFalse(fixture.client.isSessionReady)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0, "An old completion cannot release the new budget")
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 1)
        replacement.open()
        replacement.sessionCreated()
        replacement.completeSend()
        replacement.delta("Current")
        XCTAssertEqual(replacement.appendedAudio, [Fixture.frame(1)])
        XCTAssertEqual(fixture.events.texts, ["Stale", "Current"])
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A replaced run never reconnects")
        fixture.client.cancel()
    }

    func testAStaleFinishDeadlineCannotFailTheReplacement() async {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Fixture.frame(0))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(budget)
        for _ in 0..<3 { fixture.socket.completeSend() }
        fixture.socket.done("First.")
        let first = await finish.value
        XCTAssertEqual(first, "First.")
        let stale = fixture.clock.drain()
        fixture.start()
        stale.forEach { $0() }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.factory.sockets[1].cancels, 0)
        fixture.client.cancel()
    }

    func testStopCancelAndTaskCancellationWakeTheFinishPromptlyAtEveryPhase() async {
        for phase in Phase.allCases {
            for kind in Kind.allCases {
                await exerciseCancellation(phase, kind)
            }
        }
    }

    func testInformationalUnknownAndBinaryFramesNeverEndTheSession() {
        let fixture = Fixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(#"{"type":"session.updated","session":{"target_streaming_delay_ms":480}}"#)
        socket.emit(#"{"type":"transcription.language","audio_language":"fr"}"#)
        socket.emit(#"{"type":"transcription.segment","text":"seg","start":null,"end":null,"speaker_id":null}"#)
        socket.emit(#"{"type":"something.new.upstream"}"#)
        socket.emit("not json")
        socket.emit(#"["not","an","object"]"#)
        socket.delta("Alive.")
        XCTAssertEqual(fixture.events.texts, ["Alive."])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let binaryDelta = Data(#"{"type":"transcription.text.delta","text":"hi"}"#.utf8)
        guard case .delta(let fragment)? = MistralRealtimeEvent(message: .binary(binaryDelta)) else {
            return XCTFail("Binary JSON is decoded like text")
        }
        XCTAssertEqual(fragment, "hi")
        let objectError = #"{"type":"error","error":{"message":{"detail":"quota"},"code":429}}"#
        guard case .failure(let message, let code)? = MistralRealtimeEvent(message: .text(objectError)) else {
            return XCTFail("Object-shaped error messages are read from their detail")
        }
        XCTAssertEqual(message, "quota")
        XCTAssertEqual(code, 429)
        fixture.client.cancel()
    }

    func testAudioOfferedBeforeStartIsCarriedIntoTheRunInCaptureOrder() {
        let fixture = Fixture()
        fixture.client.sendAudio(Fixture.frame(0))
        fixture.client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(fixture.client.preroll.snapshot.chunkCount, 2)
        fixture.start()
        XCTAssertTrue(fixture.client.preroll.isEmpty)
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 2)
        fixture.client.sendAudio(Fixture.frame(2))
        fixture.becomeReady()
        fixture.socket.completeSend()
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.appendedAudio, (0..<3).map { Fixture.frame($0) })
        fixture.client.stop()
        fixture.client.sendAudio(Fixture.frame(3))
        XCTAssertTrue(fixture.client.preroll.isEmpty, "A stopped client holds nothing for a later start")
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 0)
    }

    func testSocketFreeSeamsKeepTheirEstablishedContract() async {
        let events = AssemblyAITestEvents()
        let client = MistralVoxtralLiveClient(apiKey: "k", makeConnection: { _ in
            fatalError("The socket-free seam must not open a connection")
        })
        client.beginSession(onTranscript: { events.transcript($0, final: $1) }, onError: { events.fail($0) })
        client.ingest(#"{"type":"session.created"}"#)
        client.ingest(#"{"type":"transcription.text.delta","text":"Commit"}"#)
        let transcript = await client.awaitFinalTranscript(budget: 30) {
            client.ingest(#"{"type":"transcription.done","text":"Committed."}"#)
        }
        XCTAssertEqual(transcript, "Committed.")
        XCTAssertEqual(events.finals, [false], "A done consumed by the wait is not also delivered")
        XCTAssertTrue(events.errors.isEmpty)
    }

    func testFinalisationBudgetIsTheCanonicalWholeFinishDeadline() {
        let client: any FinalizingStreamingTranscriptionClient = MistralVoxtralLiveClient(apiKey: "k")
        XCTAssertEqual(client.finalisationBudget, MistralVoxtralRealtime.finishBudget)
        XCTAssertEqual(
            client.finalisationBudget,
            ModelCatalog.liveCapabilities(for: MistralVoxtralRealtime.liveCatalogID).postStopFinalizeBudget
        )
        XCTAssertEqual(MistralVoxtralRealtime.finishBudget, 3)
        XCTAssertEqual(client.finalShape, .cumulativeTranscript)
        XCTAssertTrue(client.finishFlushesBufferedAudio)
    }
}

private extension MistralVoxtralIsolationTests {
    enum Phase: CaseIterable { case connecting, configuring, draining, awaitingDone }
    enum Kind: CaseIterable { case stop, cancel, task }

    func exerciseCancellation(_ phase: Phase, _ kind: Kind) async {
        let label = "\(phase) \(kind)"
        let fixture = Fixture()
        fixture.start()
        let socket = fixture.socket
        if phase != .connecting {
            socket.open()
            socket.sessionCreated()
        }
        if phase == .draining || phase == .awaitingDone { socket.completeSend() }
        fixture.client.sendAudio(Fixture.frame(0))
        socket.delta("Heard")
        let returned = expectation(description: "Finish returned after \(label)")
        let client = fixture.client
        let finish = Task {
            let transcript = await client.finishAndWait()
            returned.fulfill()
            return transcript
        }
        await fixture.waitForScheduled(budget)
        if phase == .awaitingDone { for _ in 0..<3 { socket.completeSend() } }
        let sent = socket.controls.count
        switch kind {
        case .stop: client.stop()
        case .cancel: client.cancel()
        case .task: finish.cancel()
        }
        await fulfillment(of: [returned], timeout: 2)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Heard", "The text heard so far survives \(label)")
        XCTAssertEqual(socket.cancels, 1, label)
        XCTAssertTrue(fixture.events.errors.isEmpty, "Cancellation is not a provider failure: \(label)")
        client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(socket.controls.count, sent, "Nothing is sent after \(label)")
    }
}
