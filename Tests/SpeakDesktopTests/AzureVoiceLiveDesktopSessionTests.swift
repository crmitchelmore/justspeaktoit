import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// The shared desktop session, which hosts insert from only when a recording
/// finishes, driven by the real Azure client over a fake transport.
final class AzureVoiceLiveDesktopSessionTests: XCTestCase {
    func testABarrierCorrelatedServerErrorLeavesTheRecordingFailedWithEveryWordKept() async {
        let fixture = AzureVoiceLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        let finishing = await finishThroughBarrier(fixture, session)
        fixture.socket.completed("Last words.", item: "item_b")
        fixture.socket.azureError(code: "server_error", type: "server_error",
                                  eventID: fixture.client.currentEventIDs.barrier)
        let snapshot = await finishing.value
        XCTAssertEqual(snapshot.phase, .failed, "A barrier error is never a finished recording")
        XCTAssertEqual(snapshot.text, "Confirmed words. Last words.", "Every word Azure sent is kept for recovery")
        XCTAssertEqual(snapshot.error, AzureVoiceLiveError.serverError(code: "server_error").localizedDescription)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAnAcknowledgedBarrierAndSettledItemsFinishTheRecordingWithTheWholeTranscript() async {
        let fixture = AzureVoiceLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        let finishing = await finishThroughBarrier(fixture, session)
        fixture.socket.acknowledge(sessionType: nil)
        fixture.socket.completed("Last words.", item: "item_b")
        let snapshot = await finishing.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "Confirmed words. Last words.")
        XCTAssertNil(snapshot.error)
    }

    func testCancellingTheRecordingKeepsTheDisplayedTextAndLateEventsCannotReviveIt() async {
        let fixture = AzureVoiceLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        fixture.socket.committed("item_a")
        fixture.socket.delta("Spoken so far", item: "item_a")
        let cancelled = session.cancel()
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.text, "Spoken so far")
        fixture.socket.completed("Spoken so far.", item: "item_a")
        fixture.clock.drain().forEach { $0() }
        XCTAssertEqual(session.snapshot(), cancelled, "Nothing reaches a cancelled recording")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    /// Records confirmed text, admits audio and finishes through the commit and
    /// the barrier, leaving the barrier's answer and item `item_b` outstanding.
    private func finishThroughBarrier(
        _ fixture: AzureVoiceLiveFixture, _ session: DesktopLiveSession
    ) async -> Task<DesktopLiveSession.Snapshot, Never> {
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.completed("Confirmed words.", item: "item_a")
        session.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finishing = Task { await session.finish() }
        await fixture.waitForFinishers()
        fixture.completeSends(until: "input_audio_buffer.commit")
        socket.committed("item_b")
        socket.completeSend()
        socket.completeSend()
        return finishing
    }
}
