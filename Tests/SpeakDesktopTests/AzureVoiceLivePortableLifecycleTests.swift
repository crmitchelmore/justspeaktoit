import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Readiness, admission and ordered sending of the shared Azure Voice Live
/// client, driven through the fake transport on every platform.
final class AzureVoiceLivePortableLifecycleTests: XCTestCase {
    func testConfigurationLeavesOnlyAfterTheHandshakeAndAudioWaitsForItsAcknowledgement() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let socket = fixture.socket
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        XCTAssertTrue(socket.controls.isEmpty, "Nothing leaves before the transport's handshake")
        socket.open()
        XCTAssertEqual(socket.types, ["session.update"])
        socket.completeSend()
        socket.created()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        XCTAssertEqual(socket.types, ["session.update"], "session.created is not readiness")
        XCTAssertFalse(fixture.client.isSessionReady)
        socket.azureAcknowledge()
        XCTAssertTrue(fixture.client.isSessionReady)
        XCTAssertEqual(socket.types, ["session.update", "input_audio_buffer.append"])
        socket.completeSend()
        socket.completeSend()
        XCTAssertEqual(socket.audio, [AzureVoiceLiveFixture.frame(0), AzureVoiceLiveFixture.frame(1)])
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAnAcknowledgementBeforeOurConfigurationLeftIsNotReadiness() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let socket = fixture.socket
        socket.azureAcknowledge()
        XCTAssertFalse(fixture.client.isSessionReady)
        socket.open()
        socket.completeSend()
        XCTAssertFalse(fixture.client.isSessionReady)
        socket.azureAcknowledge()
        XCTAssertTrue(fixture.client.isSessionReady)
    }

    func testHeldAudioDrainsInCaptureOrderWithOneFrameInFlightAndExactPCM() {
        let fixture = AzureVoiceLiveFixture()
        let frames = (0..<5).map { AzureVoiceLiveFixture.frame($0) }
        fixture.start()
        frames.prefix(3).forEach(fixture.client.sendAudio)
        fixture.becomeReady()
        let socket = fixture.socket
        XCTAssertEqual(socket.audio, [frames[0]], "Exactly one frame is in flight")
        frames.suffix(2).forEach(fixture.client.sendAudio)
        XCTAssertEqual(socket.audio.count, 1)
        fixture.completeSends(frames.count)
        XCTAssertEqual(socket.audio, frames, "Every append is one admitted frame, in capture order")
        XCTAssertEqual(socket.audio.reduce(Data(), +), frames.reduce(Data(), +))
        XCTAssertTrue(socket.audio.allSatisfy { $0.count == AzureVoiceLiveProtocol.frameBytes })
    }

    func testAudioOfferedBeforeStartIsHeldAndReplayedFirst() {
        let fixture = AzureVoiceLiveFixture()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(1))
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        fixture.start()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(2))
        fixture.becomeReady()
        fixture.completeSends(3)
        XCTAssertEqual(fixture.socket.audio, (0..<3).map { AzureVoiceLiveFixture.frame($0) })
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAudioThatCannotBeHeldBeforeStartIsReportedWhenTheSessionStarts() {
        let overflow = AzureVoiceLiveFixture()
        let limit = AzureVoiceLiveClient.maximumQueuedBytes / AzureVoiceLiveProtocol.frameBytes
        for index in 0...limit { overflow.client.sendAudio(AzureVoiceLiveFixture.frame(index)) }
        XCTAssertTrue(overflow.events.errors.isEmpty, "There is no session to report to yet")
        overflow.start()
        XCTAssertEqual(overflow.events.errors.map { $0 as? AzureVoiceLiveError }, [.audioOverflow])
        XCTAssertTrue(overflow.factory.sockets.isEmpty, "A session that already lost audio is not connected")

        let partial = AzureVoiceLiveFixture()
        partial.client.sendAudio(Data([1]))
        partial.start()
        XCTAssertEqual(partial.events.errors.map { $0 as? AzureVoiceLiveError }, [.invalidPCM])
        XCTAssertTrue(partial.factory.sockets.isEmpty)
    }

    func testAdmissionIsBoundedByBytesIncludingTheFrameInFlight() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let limit = AzureVoiceLiveClient.maximumQueuedBytes / AzureVoiceLiveProtocol.frameBytes
        for index in 0..<limit { fixture.client.sendAudio(AzureVoiceLiveFixture.frame(index)) }
        XCTAssertEqual(fixture.socket.audio.count, 1, "One frame is in flight; the rest wait behind it")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(limit))
        XCTAssertEqual(fixture.events.errors.map { $0 as? AzureVoiceLiveError }, [.audioOverflow])
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(limit + 1))
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.events.errors.count, 1, "The overflow is reported once")
        XCTAssertEqual(fixture.socket.audio.count, 1, "A failed run sends nothing more")
    }

    func testAdmissionIsBoundedByFramesForTinyFrames() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        let tiny = Data([1, 0])
        for _ in 0..<AzureVoiceLiveClient.maximumQueuedFrames { fixture.client.sendAudio(tiny) }
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(tiny)
        XCTAssertEqual(fixture.events.errors.map { $0 as? AzureVoiceLiveError }, [.audioOverflow])
    }

    func testEmptyFramesAreIgnoredAndPartialSamplesFailVisibly() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data())
        XCTAssertTrue(fixture.socket.audio.isEmpty)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(fixture.events.errors.map { $0 as? AzureVoiceLiveError }, [.invalidPCM])
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.socket.audio.isEmpty)
    }

    func testASessionThatIsNeverAcknowledgedFailsAtTheReadinessDeadline() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.clock.fire(AzureVoiceLiveClient.readyDeadline)
        XCTAssertEqual(fixture.events.errors.map { $0 as? AzureVoiceLiveError }, [.sessionNotReady])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAStalledSendIsReportedByOneWatchdogRatherThanATimerPerFrame() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        for index in 0..<10 {
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(index))
            fixture.socket.completeSend()
        }
        XCTAssertEqual(fixture.clock.pending(AzureVoiceLiveClient.sendDeadline), 1)
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(10))
        fixture.clock.fire(AzureVoiceLiveClient.sendDeadline)
        XCTAssertTrue(fixture.events.errors.isEmpty, "The watched send completed; the watchdog re-arms")
        XCTAssertEqual(fixture.clock.pending(AzureVoiceLiveClient.sendDeadline), 1)
        fixture.clock.fire(AzureVoiceLiveClient.sendDeadline)
        XCTAssertEqual(
            fixture.events.errors.map(\.localizedDescription),
            [StreamingClientError.transportStalled(provider: "Azure Speech").localizedDescription]
        )
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testTranscriptCallbacksKeepConfirmedTextApartFromDrafts() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item-a")
        socket.delta("Hel", item: "item-a")
        socket.delta("lo", item: "item-a")
        socket.committed("item-b")
        socket.delta("wor", item: "item-b")
        socket.completed("Hello.", item: "item-a")
        socket.transcriptionFailed(item: "item-b", message: "Synthetic")
        XCTAssertEqual(fixture.events.texts, ["Hel", "Hello", "Hello wor", "Hello.", "Hello. wor", "Hello."])
        XCTAssertEqual(fixture.events.finals, [false, false, false, true, false, false])
        XCTAssertTrue(fixture.events.errors.isEmpty, "One failed turn does not fail the session")
    }
}
