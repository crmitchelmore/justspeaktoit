import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The server's VAD commits segments while recording; a finish drains the
/// admitted audio, sends one manual commit and reads finals for a bounded
/// post-commit window. VAD commits carry no correlation id, so no final is
/// treated as the commit's own answer.
final class ElevenLabsCommitStrategyTests: XCTestCase {
    func testVADFinalsWhileRecordingAreDeliveredAndATimestampedTwinCountsOnce() async {
        let fixture = readyFixture()
        let socket = fixture.socket
        socket.emit(final("First."))
        socket.emit(timestamp("First."))
        socket.emit(timestamp("Second."))
        socket.emit(final("Second."))
        XCTAssertEqual(fixture.events.texts, ["First.", "Second."])
        XCTAssertEqual(fixture.events.finals, [true, true])
        XCTAssertEqual(commits(socket), 0, "Recording never sends a client commit")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(socket) == 1 }
        socket.completeSend()
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let text = await finish.value
        XCTAssertEqual(text, "First. Second.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishCommitsOnceAfterTheAdmittedAudioAndReadsFinalsForTheWindow() async {
        let fixture = readyFixture()
        let socket = fixture.socket
        let first = Data(repeating: 1, count: 3_200)
        let second = Data(repeating: 2, count: 3_200)
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        let finish = Task { await fixture.client.finishAndWait() }
        let again = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.finishStarted(fixture) }
        XCTAssertEqual(commits(socket), 0, "The commit waits behind the admitted audio")
        socket.completeSend()
        socket.completeSend()
        XCTAssertEqual(audio(socket), [first, second])
        XCTAssertEqual(commits(socket), 1)
        socket.emit(final("Tail one."))
        socket.completeSend()
        socket.emit(timestamp("Tail one."))
        socket.emit(final("Tail two."))
        XCTAssertEqual(socket.cancels, 0, "No final ends the window early")
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let text = await finish.value
        let repeated = await again.value
        XCTAssertEqual(text, "Tail one. Tail two.")
        XCTAssertEqual(repeated, text)
        XCTAssertTrue(fixture.events.texts.isEmpty, "Finals read by the finish are returned, not delivered")
        XCTAssertEqual(commits(socket), 1)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testFinalBeforeCommitSendCompletionDoesNotFinishAndSendFailureRemainsVisible() async {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data(repeating: 1, count: 320)) // Ten milliseconds.
        fixture.socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(fixture.socket) == 1 }
        fixture.socket.emit(final("Short."))
        XCTAssertEqual(fixture.socket.cancels, 0, "Receiving text does not prove the pending send succeeded")
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        let text = await finish.value
        XCTAssertEqual(text, "Short.")
        XCTAssertEqual(fixture.events.errors.count, 1, "Error must precede the finish return")
    }

    func testInlineFinalBeforeCommitSendCompletionIsKept() async {
        let fixture = readyFixture()
        let socket = fixture.socket
        socket.onSend = { message in
            if case .text(let text) = message, text.contains("\"commit\":true") {
                socket.emit(#"{"message_type":"committed_transcript","text":"Inline."}"#)
            }
        }
        fixture.client.sendAudio(Data(repeating: 1, count: 320))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(socket) == 1 }
        XCTAssertEqual(socket.cancels, 0)
        socket.completeSend()
        fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
        let text = await finish.value
        XCTAssertEqual(text, "Inline.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testPostCommitWindowEndsTheFinishWithWhatItHas() async {
        for receivesFinal in [false, true] {
            let fixture = readyFixture()
            fixture.client.sendAudio(Data(repeating: 0, count: 320))
            fixture.socket.completeSend()
            let finish = Task { await fixture.client.finishAndWait() }
            await fixture.settle { self.commits(fixture.socket) == 1 }
            fixture.socket.completeSend()
            if receivesFinal { fixture.socket.emit(final("")) }
            fixture.clock.fire(ElevenLabsLiveClient.finishBudget)
            let text = await finish.value
            XCTAssertNil(text)
            XCTAssertTrue(fixture.events.errors.isEmpty, "A blank or absent final is not a failure")
            XCTAssertEqual(fixture.socket.cancels, 1)
        }
    }

    func testWholeFinishDeadlineBoundsSlowDrainAndReturnsWhatItHas() async {
        let fixture = readyFixture()
        fixture.commit("Saved.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.finishStarted(fixture) }
        fixture.clock.fire(ElevenLabsLiveClient.sendDeadline)
        XCTAssertTrue(fixture.events.errors.isEmpty, "A finish is bounded by its own deadline")
        fixture.clock.fire(ElevenLabsLiveClient.finishDrainBudget)
        let text = await finish.value
        XCTAssertEqual(text, "Saved.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(commits(fixture.socket), 0, "The stalled audio send was never overtaken by the commit")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testPreStartAudioIsReplayedInOrderThroughTheSameAdmissionPath() {
        let fixture = ElevenLabsFixture()
        let first = Data([1, 0, 2, 0])
        let second = Data([3, 0, 4, 0])
        fixture.client.sendAudio(first)
        fixture.client.sendAudio(second)
        fixture.start()
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        fixture.becomeReady()
        XCTAssertEqual(audio(fixture.socket), [first])
        fixture.socket.completeSend()
        XCTAssertEqual(audio(fixture.socket), [first, second])
        fixture.client.cancel()
    }

    func testNoAudioFinishDoesNotWaitForReadinessOrSendFictitiousAudio() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let text = await fixture.client.finishAndWait()
        XCTAssertNil(text)
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testPartialSampleChunksAreSentAsCapturedAndUnsupportedRatesFail() {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data([1]))
        XCTAssertEqual(audio(fixture.socket), [Data([1])])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
        for rate in [12_345, 0, Int.min, Int.max] {
            let factory = AssemblyAISocketFactory()
            let events = AssemblyAITestEvents()
            let client = ElevenLabsLiveClient(apiKey: "test", sampleRate: rate, makeConnection: { factory.make($0) })
            client.start(onTranscript: { _, _ in }, onError: { events.fail($0) })
            XCTAssertEqual(events.errors.first as? ElevenLabsStreamingError, .invalidSampleRate(rate))
            XCTAssertTrue(factory.sockets.isEmpty)
        }
    }

    func testRetiredPostCommitWindowCannotEndTheNextSession() async {
        let fixture = readyFixture()
        fixture.client.sendAudio(Data(repeating: 1, count: 320))
        fixture.socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { self.commits(fixture.socket) == 1 }
        fixture.socket.completeSend()
        fixture.socket.emit(final("First."))
        let oldDeadlines = fixture.clock.drain()
        fixture.client.cancel()
        _ = await finish.value
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.emit(ElevenLabsFixture.started())
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }
}

private extension ElevenLabsCommitStrategyTests {
    /// The finish has armed its overall bound beside the startup deadline,
    /// which has the same length in production.
    func finishStarted(_ fixture: ElevenLabsFixture) -> Bool {
        XCTAssertEqual(ElevenLabsLiveClient.finishDrainBudget, ElevenLabsLiveClient.readyDeadline)
        return fixture.clock.pending(ElevenLabsLiveClient.finishDrainBudget) == 2
    }

    func readyFixture() -> ElevenLabsFixture {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        return fixture
    }

    func final(_ text: String) -> String {
        #"{"message_type":"committed_transcript","text":"\#(text)"}"#
    }

    func timestamp(_ text: String) -> String {
        #"{"message_type":"committed_transcript_with_timestamps","text":"\#(text)","words":[]}"#
    }

    func commits(_ socket: AssemblyAITestSocket) -> Int {
        socket.objects.filter { ($0["commit"] as? Bool) == true }.count
    }

    func audio(_ socket: AssemblyAITestSocket) -> [Data] {
        socket.objects.compactMap {
            guard let base64 = $0["audio_base_64"] as? String, !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64)
        }
    }
}
