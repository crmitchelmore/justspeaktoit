import Foundation
import XCTest
@testable import SpeakCore

final class GladiaConfiguredFinishTests: XCTestCase {
    func testHeldPCMDrainsBeforeCapturedGraceControlCompletionAndFinalWindow() async throws {
        let fixture = GladiaConfiguredFixture(grace: 0.75, window: 2)
        defer { fixture.client.cancel() }
        fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0))
        fixture.client.sendAudio(Data([1, 2]))
        let finish = try await fixture.beginFinish(in: self)
        XCTAssertEqual(fixture.client.admittedAudioBytes, 4_800)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 2)
        XCTAssertFalse(socket.stopRecordingSent)
        socket.completeSend()
        XCTAssertEqual(fixture.client.admittedAudioBytes, 1_600)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 1)
        XCTAssertEqual(socket.sentAudio.map(\.count), [3_200, 1_600])
        XCTAssertFalse(fixture.clock.scheduledDelays.contains(0.75))
        socket.completeSend()
        XCTAssertEqual(fixture.client.admittedAudioBytes, 0)
        XCTAssertEqual(fixture.client.admittedAudioChunks, 0)
        XCTAssertTrue(fixture.clock.scheduledDelays.contains(0.75))
        fixture.clock.advance(by: 0.5)
        XCTAssertFalse(socket.stopRecordingSent)
        fixture.clock.advance(by: 0.25)
        XCTAssertTrue(socket.stopRecordingSent)
        XCTAssertFalse(fixture.clock.scheduledDelays.contains(2))
        socket.completeSend()
        XCTAssertTrue(fixture.clock.scheduledDelays.contains(2))
        socket.final("Tail.", id: "1")
        socket.emit(GladiaFrames.endRecording)
        XCTAssertEqual(socket.cancelCount, 0)
        socket.endSession()
        let result = try await fixture.result(finish)
        XCTAssertEqual(result, "Tail.")
        XCTAssertEqual(fixture.log.timeline, ["final:Tail."])
        fixture.clock.advance(by: 60)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testPendingInitiationDrainDeadlineFailsAsNotReadyAndLateReplyOpensNothing() async throws {
        let fixture = GladiaConfiguredFixture()
        fixture.start(open: false)
        fixture.client.sendAudio(GladiaHarness.pcm(0))
        let finish = try await fixture.beginFinish(in: self)
        fixture.clock.advance(by: 1.5)
        let result = try await fixture.result(finish)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.log.errors.first as? GladiaStreamingError, .sessionNotReady)
        fixture.sessions.grant()
        XCTAssertTrue(fixture.sockets.sockets.isEmpty)
    }

    func testHeldPCMAndHeldControlHaveSeparateStalledErrorsWithoutExtendingOnText() async throws {
        for heldPCM in [true, false] {
            let fixture = GladiaConfiguredFixture()
            defer { fixture.client.cancel() }
            fixture.start()
            let socket = try XCTUnwrap(fixture.sockets.sockets.last)
            fixture.client.sendAudio(GladiaHarness.pcm(0))
            if !heldPCM { socket.completeSend() }
            let finish = try await fixture.beginFinish(in: self)
            XCTAssertEqual(socket.stopRecordingSent, !heldPCM)
            socket.partial("retained", id: "1")
            fixture.clock.advance(by: 1.5)
            _ = try await fixture.result(finish)
            guard case .transportStalled(let provider)? = fixture.log.errors.first as? StreamingClientError else {
                XCTFail("Expected owned PCM/control transport stall"); continue
            }
            XCTAssertEqual(provider, "Gladia")
            XCTAssertEqual(fixture.log.timeline, ["partial:retained", "error"])
        }
    }

    func testFinalWindowStartsAfterControlCompletionAndRequiresEndSession() async throws {
        let fixture = GladiaConfiguredFixture(window: 0.5)
        defer { fixture.client.cancel() }
        fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0)); socket.completeSend()
        let finish = try await fixture.beginFinish(in: self)
        fixture.clock.advance(by: 1)
        XCTAssertTrue(fixture.log.errors.isEmpty)
        socket.completeSend()
        socket.final("Saved words.", id: "1")
        socket.emit(GladiaFrames.endRecording)
        fixture.clock.advance(by: 0.5)
        let result = try await fixture.result(finish)
        XCTAssertEqual(result, "Saved words.")
        XCTAssertEqual(fixture.log.errors.first as? GladiaStreamingError, .missingCompletion)
    }

    func testEndSessionAfterActualControlHandoffCanCompleteBeforeItsSendCallback() async throws {
        let fixture = GladiaConfiguredFixture()
        fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0)); socket.completeSend()
        let finish = try await fixture.beginFinish(in: self)
        XCTAssertTrue(socket.stopRecordingSent)
        XCTAssertEqual(socket.heldSendCount, 1)
        socket.final("Complete.", id: "1"); socket.endSession()
        let result = try await fixture.result(finish)
        XCTAssertEqual(result, "Complete.")
        fixture.clock.advance(by: 60)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testConcurrentConfiguredFinishesShareOneControlAndTheSameOutcome() async throws {
        let fixture = GladiaConfiguredFixture()
        defer { fixture.client.cancel() }
        fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0)); socket.completeSend()
        let first = try await fixture.beginFinish(in: self)
        let second = fixture.ownFinish(in: self)
        // Wait for actual continuation admission, with a monotonic wall-clock
        // bound rather than an arbitrary number of scheduler yields.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while fixture.client.finishWaiterCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard fixture.client.finishWaiterCount == 2 else {
            first.task.cancel(); second.task.cancel(); fixture.client.cancel()
            XCTFail("Both configured finish continuations must be admitted before completing the transport")
            throw GladiaConfiguredFixture.Timeout()
        }
        XCTAssertEqual(socket.sentTexts, [GladiaLiveProtocol.stopRecordingJSON])
        XCTAssertEqual(fixture.clock.count(of: 1.5), 1, "Obsolete drain arm must not schedule beside control")
        socket.completeSend()
        socket.final("Shared.", id: "1"); socket.endSession()
        let firstResult = try await fixture.result(first)
        let secondResult = try await fixture.result(second)
        XCTAssertEqual(firstResult, "Shared.")
        XCTAssertEqual(secondResult, firstResult)
        fixture.clock.advance(by: 60)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testOldGraceAndSendCompletionsCannotSendStopOrTimeoutReplacement() async throws {
        let fixture = GladiaConfiguredFixture(grace: 0.75)
        defer { fixture.client.cancel() }
        fixture.start()
        let old = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0)); old.completeSend()
        let finish = try await fixture.beginFinish(in: self)
        finish.task.cancel()
        _ = try await fixture.result(finish)
        fixture.start()
        let next = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(1))
        fixture.clock.advance(by: 2)
        old.completeAllSends(); old.endSession()
        XCTAssertFalse(old.stopRecordingSent)
        XCTAssertFalse(next.stopRecordingSent)
        XCTAssertEqual(next.cancelCount, 0)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }
}
