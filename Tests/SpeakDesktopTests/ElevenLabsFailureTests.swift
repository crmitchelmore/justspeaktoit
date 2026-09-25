import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class ElevenLabsFailureTests: XCTestCase {
    // MARK: - Explicit errors before success, reported once

    func testAuthErrorFailsWithInvalidKeyOnceAndCancels() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(ElevenLabsFixture.error("auth_error", "no scribe access"))
        XCTAssertEqual(fixture.events.errors.count, 1)
        guard case StreamingClientError.invalidAPIKey(let provider)? = fixture.events.errors.first else {
            return XCTFail("Expected an invalid-key failure")
        }
        XCTAssertEqual(provider, "ElevenLabs")
        XCTAssertEqual(fixture.socket.cancels, 1)
        fixture.socket.emit(ElevenLabsFixture.committed("Late."))
        XCTAssertEqual(fixture.events.texts, [], "A failed run delivers nothing further")
    }

    func testTerminalServerErrorFailsOnceWarningIsSurvivedAndUnknownFramesAreIgnored() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(#"{"message_type":"warning","warning":"clipping"}"#)
        socket.emit(#"{"message_type":"language_detected","language_code":"en"}"#)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.client.isConnected, "Warnings and unknown frames leave the session open")
        socket.emit(ElevenLabsFixture.error("transcriber_error", "model failure"))
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(
            fixture.events.errors.first as? ElevenLabsStreamingError,
            .serverError(type: "transcriber_error", message: "model failure")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testServerErrorWhileAwaitingTheTrailingFinalEndsTheFinishVisibly() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        fixture.commit("Saved.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { ElevenLabsFixture.commitCount(socket) == 2 }
        socket.completeSend()
        socket.emit(ElevenLabsFixture.error("quota_exceeded", "limit reached"))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Saved.", "The best available text survives the failure")
        XCTAssertEqual(
            fixture.events.errors.first as? ElevenLabsStreamingError,
            .serverError(type: "quota_exceeded", message: "limit reached")
        )
        XCTAssertEqual(socket.cancels, 1)
    }

    func testMissingKeyFailsWithoutCreatingATransport() {
        let fixture = ElevenLabsFixture(key: " \n")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertTrue(fixture.events.errors.first is ElevenLabsLiveError)
    }

    // MARK: - Bounded deadlines

    func testReadinessAndSendStallsFailWithinTheirScheduledBudgets() {
        let connecting = ElevenLabsFixture()
        connecting.start()
        connecting.socket.open()
        connecting.clock.fire(ElevenLabsLiveClient.readyDeadline)
        XCTAssertTrue(connecting.events.errors.first is ElevenLabsLiveError)
        XCTAssertEqual(connecting.socket.cancels, 1)

        let stalled = ElevenLabsFixture()
        stalled.start()
        stalled.becomeReady()
        stalled.client.sendAudio(Data(repeating: 0, count: 3_200))
        stalled.clock.fire(ElevenLabsLiveClient.sendDeadline)
        XCTAssertEqual(stalled.events.errors.count, 1)
        guard case StreamingClientError.transportStalled? = stalled.events.errors.first else {
            return XCTFail("Expected a visible transport stall")
        }
        XCTAssertEqual(stalled.socket.cancels, 1)
    }

    // MARK: - Late callbacks and reused sessions

    func testOldOpenReceiveSendAndDeadlineCannotMutateAReplacementSession() {
        let fixture = ElevenLabsFixture()
        fixture.start()
        let old = fixture.factory.sockets[0]
        old.open()
        old.emit(ElevenLabsFixture.started())
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        old.open()
        old.completeSend(URLError(.networkConnectionLost))
        old.emit(ElevenLabsFixture.committed("Stale."))
        oldDeadlines.forEach { $0() }
        XCTAssertFalse(fixture.client.isConnected)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertEqual(old.cancels, 1)
        replacement.open()
        replacement.emit(ElevenLabsFixture.started())
        fixture.commit("Current.", socket: replacement)
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(ElevenLabsFixture.audioChunks(replacement).last, Data(repeating: 2, count: 3_200))
        XCTAssertEqual(fixture.events.texts, ["Current."])
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "A stopped run never reconnects")
        fixture.client.cancel()
    }

    func testAReusedClientRunsAFreshSessionAfterAGracefulFinish() async {
        let fixture = ElevenLabsFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.commit("First session.")
        fixture.client.stop()
        XCTAssertEqual(fixture.socket.cancels, 1)

        fixture.start()
        let second = fixture.factory.sockets[1]
        second.open()
        second.emit(ElevenLabsFixture.started())
        fixture.commit("Second session.", socket: second)
        fixture.client.sendAudio(Data(repeating: 7, count: 3_200))
        XCTAssertEqual(ElevenLabsFixture.audioChunks(second).count, 5)
        second.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { ElevenLabsFixture.commitCount(second) == 2 }
        second.completeSend()
        second.emit(ElevenLabsFixture.committed(""))
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Second session.", "A reused client starts each session's transcript fresh")
        XCTAssertEqual(fixture.factory.sockets.count, 2)
    }

    // MARK: - Offline seams remain compatible

    func testOfflineFullTranscriptPrerollAndContractFlagsRemainCompatible() async {
        let fixture = ElevenLabsFixture()
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.preroll.drain(), [Data([1, 2])])
        XCTAssertEqual(fixture.client.finalShape, .standaloneSegments)
        XCTAssertTrue(fixture.client.finishFlushesBufferedAudio)
        fixture.client.parseTranscriptResponse(ElevenLabsFixture.committed("Yes."))
        fixture.client.parseTranscriptResponse(ElevenLabsFixture.committed("Yes."))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
        fixture.client.stop()
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertTrue(fixture.client.preroll.isEmpty, "A stopped session buffers nothing further")
    }

}
