import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A finish drains admitted audio, commits it, sends the barrier and returns
/// once the commit and the barrier are acknowledged and every announced item
/// has settled. Only an empty-buffer answer to this client's own commit is
/// benign; every other server error, including one that names the barrier,
/// is published as a failure before the finish returns.
final class AzureVoiceLiveFinalisationTests: XCTestCase {
    func testFinishSendsEveryFrameThenTheCommitThenTheBarrierAndReturnsTheWholeTranscript() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.completed("First turn.", item: "item_a")
        let frames = (0..<3).map { AzureVoiceLiveFixture.frame($0) }
        frames.forEach(fixture.client.sendAudio)
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        XCTAssertEqual(socket.audio, [frames[0]])
        fixture.completeSends(until: "input_audio_buffer.commit")
        XCTAssertEqual(socket.audio, frames, "Every admitted frame leaves before the commit")
        let ids = fixture.client.currentEventIDs
        XCTAssertEqual(socket.azureCommits.first?["event_id"] as? String, ids.commit)
        socket.committed("item_b")
        socket.completeSend()
        let barrier = socket.azureSessionUpdates.last
        XCTAssertEqual(barrier?["event_id"] as? String, ids.barrier)
        XCTAssertEqual((barrier?["session"] as? [String: Any])?["modalities"] as? [String], ["text"])
        socket.completeSend()
        socket.delta("Sec", item: "item_b")
        socket.acknowledge(sessionType: nil)
        XCTAssertEqual(socket.cancels, 0, "The finish waits for the item the commit announced")
        socket.completed("Second turn.", item: "item_b")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "First turn. Second turn.")
        XCTAssertEqual(fixture.events.texts, ["First turn."], "Text arriving while finishing is returned once")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertFalse(socket.types.contains("response.create"))
    }

    func testACommittedEventBeforeOurCommitLeftDoesNotAcknowledgeIt() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        // Server VAD commits while our commit still waits behind queued audio.
        socket.committed("item_vad")
        socket.completed("Before stop.", item: "item_vad")
        fixture.completeSends(until: "input_audio_buffer.commit")
        socket.completeSend()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
        XCTAssertEqual(socket.cancels, 0, "Only an acknowledgement after our commit left can settle it")
        XCTAssertEqual(fixture.client.pendingFinishCount, 1)
        socket.committed("item_tail")
        XCTAssertEqual(socket.cancels, 0, "The item our commit announced has not settled")
        socket.completed("Tail.", item: "item_tail")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Before stop. Tail.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAFinishWhoseCommitIsNeverAcknowledgedFailsAtTheBudgetInsteadOfSucceeding() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_vad")
        socket.completed("Kept.", item: "item_vad")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        fixture.completeSends(until: "input_audio_buffer.commit")
        socket.completeSend()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
        XCTAssertEqual(socket.cancels, 0)
        fixture.clock.fire(fixture.client.finishBudget)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Kept.", final: true), .error("\(AzureSpeechError.timedOut)"), .finished("Kept.")
        ], "The timeout is published before the finish returns the confirmed text")
    }

    func testAnEmptyBufferAnswerToOurOwnCommitIsBenignButStillWaitsForTheBarrierAndEveryItem() async {
        for correlated in [true, false] {
            let fixture = AzureVoiceLiveFixture()
            fixture.start()
            fixture.becomeReady()
            let socket = fixture.socket
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            socket.committed("item_a")
            let finish = fixture.finish()
            await fixture.waitForFinishers()
            fixture.completeSends(until: "input_audio_buffer.commit")
            socket.azureError(code: AzureVoiceLiveProtocol.commitEmptyCode,
                              eventID: correlated ? fixture.client.currentEventIDs.commit : nil)
            socket.completeSend()
            socket.completeSend()
            XCTAssertEqual(socket.cancels, 0, "The barrier is still unanswered")
            socket.acknowledge(sessionType: nil)
            XCTAssertEqual(socket.cancels, 0, "Server VAD's item has not settled")
            socket.completed("All of it.", item: "item_a")
            let transcript = await finish.value
            XCTAssertEqual(transcript, "All of it.")
            XCTAssertTrue(fixture.events.errors.isEmpty, "correlated: \(correlated)")
        }
    }

    func testTheFinishBudgetFailsAFinishWhoseItemNeverCompletes() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = await fixture.finishThroughBarrier(committing: "item_a")
        socket.acknowledge(sessionType: nil)
        socket.delta("Unfinished", item: "item_a")
        fixture.clock.fire(fixture.client.finishBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Unfinished", final: false), .error("\(AzureSpeechError.timedOut)"), .finished(nil)
        ])
    }

    func testAStopDuringTheHandshakeKeepsTheOpeningAudioAndCommitsItOnceAcknowledged() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let socket = fixture.socket
        let opening = AzureVoiceLiveFixture.frame(7)
        fixture.client.sendAudio(opening)
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        XCTAssertEqual(fixture.clock.pending(AzureVoiceLiveClient.finishReadyBudget), 1)
        XCTAssertTrue(socket.controls.isEmpty)
        fixture.becomeReady()
        XCTAssertEqual(socket.audio, [opening])
        fixture.completeSends(until: "input_audio_buffer.commit")
        socket.committed("item_a")
        socket.completeSend()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
        socket.completed("Opening words.", item: "item_a")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
    }

    func testAStopDuringTheHandshakeFailsVisiblyWhenAzureNeverAcknowledges() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        fixture.clock.fire(AzureVoiceLiveClient.finishReadyBudget)
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAFinishWithNoAudioEndsAtOnceWithoutARoundTrip() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.socket.types, ["session.update"])
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testConcurrentFinishCallersShareOneResultAndOneCommit() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let first = fixture.finish()
        let second = fixture.finish()
        await fixture.waitForFinishers(2)
        fixture.completeSends(until: "input_audio_buffer.commit")
        socket.committed("item_a")
        socket.completeSend()
        socket.completeSend()
        socket.acknowledge(sessionType: nil)
        socket.completed("Once.", item: "item_a")
        let results = await [first.value, second.value]
        XCTAssertEqual(results, ["Once.", "Once."])
        XCTAssertEqual(socket.azureCommits.count, 1)
        XCTAssertEqual(socket.azureSessionUpdates.count, 2, "One configuration and one barrier")
    }
}
