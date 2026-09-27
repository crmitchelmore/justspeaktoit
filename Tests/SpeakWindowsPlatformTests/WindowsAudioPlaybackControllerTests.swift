#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsAudioPlaybackControllerTests: XCTestCase {
    private var backend = PlaybackTestBackend()
    private var recorder = PlaybackTestPresenter()
    private var controller: WindowsAudioPlaybackController!

    override func setUp() {
        super.setUp()
        backend = PlaybackTestBackend()
        recorder = PlaybackTestPresenter()
        controller = WindowsAudioPlaybackController(
            backend: backend, presenter: recorder.presenter, progressInterval: .milliseconds(5), stopTimeout: 0.25
        )
    }
    override func tearDown() async throws {
        backend.openAllGates()
        backend.handles.forEach { $0.acknowledgeQuiet() }
        try await controller.close()
        controller = nil
        try await super.tearDown()
    }
    private func play(_ id: UUID = UUID()) async throws -> PlaybackTestHandle {
        let count = backend.handles.count
        try controller.play(recordID: id, path: "fixture.wav", knownDuration: 2)
        await playbackEventually { self.backend.handles.count > count }
        let handle = try XCTUnwrap(backend.handles.last)
        await playbackEventually { handle.counts.started == 1 }
        return handle
    }

    func testPlay_OnlyPresentsAcknowledgedProgressAndUsesNativeDuration() async throws {
        let id = UUID(), handle = try await play(id)
        await playbackEventually { self.recorder.displays.last?.state == .preparing }
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(recorder.displays.count, 1)
        handle.set(state: .playing, position: 0.25, duration: 0.5)
        await playbackEventually { self.recorder.displays.last?.state == .playing }
        XCTAssertEqual(recorder.displays.last?.text, "00:00.25 / 00:00.25")
        XCTAssertEqual(controller.activity?.recordID, id)
        handle.set(state: .paused, position: 0.25, duration: 0.5)
        await playbackEventually { self.recorder.displays.last?.state == .paused }
        XCTAssertTrue(recorder.statuses.isEmpty)
    }

    func testStop_AcknowledgesSilenceBeforeWaitingForCodecRelease() async throws {
        let gate = PlaybackTestGate(), id = UUID()
        backend.enqueue(PlaybackTestPlan(destroyGate: gate))
        let handle = try await play(id)
        try await controller.stopAndWait()
        await playbackEventually { gate.entered }
        XCTAssertTrue(handle.snapshot().outputIsQuiet)
        XCTAssertEqual(handle.counts.destroyed, 0)
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        await playbackEventually { self.idle(id) != nil }
        XCTAssertNil(controller.activity)
        gate.open()
        await playbackEventually { self.controller.pendingReleaseCount == 0 }
    }

    func testCancellationRequestAlone_DoesNotAcknowledgeSilenceOrStartReplacement() async throws {
        backend.enqueue(PlaybackTestPlan(quietOnCancel: false))
        let first = try await play()
        try controller.play(recordID: UUID(), path: "second.wav", knownDuration: 1)
        await playbackEventually { self.backend.handles.count == 2 && first.counts.cancelled == 1 }
        let next = try XCTUnwrap(backend.handles.last)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(next.counts.started, 0)
        first.acknowledgeQuiet()
        await playbackEventually { next.counts.started == 1 }
    }

    func testMissingStopAcknowledgement_ThrowsAndKeepsOwnership() async throws {
        backend.enqueue(PlaybackTestPlan(quietOnCancel: false))
        let handle = try await play()
        do { try await controller.stopAndWait(); XCTFail("False silence acknowledgement") } catch {}
        XCTAssertEqual(handle.counts.destroyed, 0)
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        handle.acknowledgeQuiet()
    }

    func testRapidSwitching_HasGlobalTwoJobBoundWithBlockedRetirement() async throws {
        let gate = PlaybackTestGate()
        backend.enqueue(PlaybackTestPlan(destroyGate: gate))
        _ = try await play()
        let second = UUID()
        _ = try await play(second)
        await playbackEventually { gate.entered }
        for _ in 0..<25 {
            XCTAssertThrowsError(try controller.play(recordID: UUID(), path: "later.wav", knownDuration: nil))
        }
        XCTAssertEqual(controller.pendingReleaseCount, 2)
        XCTAssertEqual(backend.handles.count, 2)
        XCTAssertEqual(controller.activity?.recordID, second)
        gate.open()
        await playbackEventually { self.controller.pendingReleaseCount == 1 }
    }

    func testCloseDuringSuspendedOpen_JoinsAdmissionAndNeverStartsAfterClose() async throws {
        let gate = PlaybackTestGate(), returned = PlaybackTestFlag()
        backend.enqueue(PlaybackTestPlan(openGate: gate))
        try controller.play(recordID: UUID(), path: "blocked.wav", knownDuration: nil)
        await playbackEventually { gate.entered }
        let owned = try XCTUnwrap(controller)
        let closing = Task { try await owned.close(); returned.set() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(returned.isSet)
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        gate.open()
        try await closing.value
        XCTAssertTrue(returned.isSet)
        XCTAssertEqual(backend.handles.first?.counts.started, 0)
        XCTAssertEqual(backend.handles.first?.counts.destroyed, 1)
        XCTAssertNil(controller.activity)
        XCTAssertThrowsError(try controller.play(recordID: UUID(), path: "late.wav", knownDuration: nil))
    }

    func testStopDuringSuspendedOpen_CanAcknowledgeWithoutWaitingAndForbidsLaterStart() async throws {
        let gate = PlaybackTestGate()
        backend.enqueue(PlaybackTestPlan(openGate: gate))
        try controller.play(recordID: UUID(), path: "blocked.wav", knownDuration: nil)
        await playbackEventually { gate.entered }
        try await controller.stopAndWait()
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(backend.handles.first?.counts.started, 0)
        gate.open()
        await playbackEventually { self.controller.pendingReleaseCount == 0 }
        XCTAssertEqual(backend.handles.first?.counts.started, 0)
    }

    func testCompletionInsideStart_DoesNotReleaseBeforeStartReturns() async throws {
        for status in [WindowsAudioPlaybackCompletion.Status.finished, .failed("Immediate failure")] {
            let gate = PlaybackTestGate()
            backend.enqueue(PlaybackTestPlan(startGate: gate, completeOnStart: .init(status: status, played: 0)))
            try controller.play(recordID: UUID(), path: "immediate.wav", knownDuration: 1)
            await playbackEventually { gate.entered }
            let handle = try XCTUnwrap(backend.handles.last)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(handle.counts.destroyAttempts, 0)
            gate.open()
            await playbackEventually { handle.counts.destroyed == 1 }
            XCTAssertFalse(handle.destroyedBeforeStartReturn)
        }
    }

    func testCancellationDuringStart_RespectsStartReturnBarrier() async throws {
        let gate = PlaybackTestGate()
        backend.enqueue(PlaybackTestPlan(startGate: gate))
        try controller.play(recordID: UUID(), path: "starting.wav", knownDuration: 1)
        await playbackEventually { gate.entered }
        controller.stop()
        let handle = try XCTUnwrap(backend.handles.last)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(handle.counts.destroyAttempts, 0)
        gate.open()
        try await controller.stopAndWait()
        await playbackEventually { handle.counts.destroyed == 1 }
        XCTAssertFalse(handle.destroyedBeforeStartReturn)
    }

    func testDelayedSameRecordPublication_CannotOvertakeReplacement() async throws {
        let id = UUID(), gate = PlaybackTestGate()
        let old = try await play(id)
        recorder.onShow { display in if display.state == .idle { _ = gate.wait() } }
        old.complete(.init(status: .finished, played: 2))
        await playbackEventually { gate.entered }
        _ = try await play(id)
        XCTAssertEqual(controller.activity?.state, .preparing)
        gate.open()
        await playbackEventually { self.recorder.displays.last?.state == .preparing }
        let revisions = recorder.displays.map(\.revision)
        XCTAssertEqual(revisions, revisions.sorted())
        XCTAssertEqual(Set(revisions).count, revisions.count)
        recorder.onShow { _ in }
    }

    func testReentrantPresenter_CanStopWithoutDeadlocking() async throws {
        let owned = try XCTUnwrap(controller)
        recorder.onShow { display in if display.state == .preparing { owned.stop() } }
        try controller.play(recordID: UUID(), path: "reentrant.wav", knownDuration: 1)
        await playbackEventually { self.controller.pendingReleaseCount == 0 }
        XCTAssertNil(controller.activity)
        recorder.onShow { _ in }
    }

    /// Only the user's Stop reports "Playback stopped.". Stopping to make way
    /// for another row, a search or deletion, recording or import must not
    /// overwrite the status that work has already set.
    func testOnlyAnAnnouncedStop_ReportsPlaybackStopped() async throws {
        let makingWay: [@Sendable (WindowsAudioPlaybackController) async throws -> Void] = [
            { $0.stop(unless: UUID()) }, { $0.stop() }, { try await $0.stopAndWait() }
        ]
        for makeWay in makingWay {
            let id = UUID()
            _ = try await play(id)
            try await makeWay(try XCTUnwrap(controller))
            await playbackEventually { self.recorder.displays.last == self.idle(id) }
        }
        _ = try await play()
        controller.stop(announcing: true)
        // Statuses are delivered in order: an earlier one would precede this.
        await playbackEventually { !self.recorder.statuses.isEmpty }
        XCTAssertEqual(recorder.statuses, ["Playback stopped."])
    }

    private func idle(_ id: UUID) -> WindowsAudioPlaybackDisplay? {
        recorder.displays.last { $0.recordID == id && $0.state == .idle }
    }

    func testStaleStatusRevision_IsRejectedAfterNewRun() async throws {
        let handle = try await play()
        handle.complete(.init(status: .finished, played: 1))
        await playbackEventually { !self.recorder.notices.isEmpty }
        let old = try XCTUnwrap(recorder.notices.last)
        XCTAssertTrue(controller.isCurrent(revision: old.revision))
        _ = try await play()
        XCTAssertFalse(controller.isCurrent(revision: old.revision))
    }

    func testDestroyFailure_RetainsSlotAndCloseRetriesWithoutLosingHandle() async throws {
        backend.enqueue(PlaybackTestPlan(destroyFailures: 1))
        let handle = try await play()
        controller.stop()
        await playbackEventually { handle.counts.destroyAttempts == 1 }
        XCTAssertEqual(handle.counts.destroyed, 0)
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        try await controller.close()
        XCTAssertEqual(handle.counts.destroyed, 1)
        XCTAssertEqual(controller.pendingReleaseCount, 0)
    }

    func testStartFailure_ReportsAsynchronouslyAndReleases() async throws {
        backend.enqueue(PlaybackTestPlan(startFailure: "Injected start failure"))
        try controller.play(recordID: UUID(), path: "fail.wav", knownDuration: nil)
        await playbackEventually { self.recorder.statuses.contains("Playback failed: Injected start failure") }
        XCTAssertEqual(backend.handles.first?.counts.destroyed, 1)
        XCTAssertNil(controller.activity)
    }

    func testTogglePause_CommandsAreOffCallerAndAcknowledgedInDisplay() async throws {
        let id = UUID(), handle = try await play(id)
        XCTAssertFalse(controller.togglePause(recordID: UUID()))
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { self.recorder.displays.last?.state == .paused }
        XCTAssertEqual(handle.counts.paused, 1)
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { self.recorder.displays.last?.state == .playing }
        XCTAssertEqual(handle.counts.resumed, 1)
    }

}

extension WindowsAudioPlaybackControllerTests {
    func testBlockedPresenter_CoalescesProgressToTheLatestSnapshot() async throws {
        let gate = PlaybackTestGate()
        recorder.onShow { display in if display.state == .preparing { _ = gate.wait() } }
        let handle = try await play()
        await playbackEventually { gate.entered }
        for index in 1...10 {
            handle.set(state: .playing, position: Double(index) / 10, duration: 2)
            try await Task.sleep(for: .milliseconds(10))
        }
        // A late timer on a loaded runner may not have polled the final value
        // yet; a second poll after it proves that value is the retained one.
        let polled = handle.snapshotReads
        await playbackEventually { handle.snapshotReads >= polled + 2 }
        gate.open()
        await playbackEventually { self.recorder.displays.last?.text == "00:01.00 / 00:01.00" }
        XCTAssertEqual(recorder.displays.count, 2, "Only one in-flight and one latest publication may be retained")
    }

    func testClose_WaitsForAnAlreadyExecutingDisplayCallback() async throws {
        let gate = PlaybackTestGate(), returned = PlaybackTestFlag()
        recorder.onShow { display in if display.state == .preparing { _ = gate.wait() } }
        _ = try await play()
        await playbackEventually { gate.entered }
        let owned = try XCTUnwrap(controller)
        let closing = Task { try await owned.close(); returned.set() }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(returned.isSet)
        gate.open()
        try await closing.value
        XCTAssertTrue(returned.isSet)
        let count = recorder.displays.count
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(recorder.displays.count, count)
    }

    func testRepeatedDestroyFailure_CloseReportsItAndKeepsTheHandleForRetry() async throws {
        backend.enqueue(PlaybackTestPlan(destroyFailures: 2))
        let handle = try await play()
        controller.stop()
        await playbackEventually { handle.counts.destroyAttempts == 1 }
        do { try await controller.close(); XCTFail("Close hid the release failure") } catch {}
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        XCTAssertEqual(handle.counts.destroyed, 0)
        try await controller.close()
        XCTAssertEqual(controller.pendingReleaseCount, 0)
        XCTAssertEqual(handle.counts.destroyed, 1)
    }

    func testDisplayText_BoundsFiniteOverflowAndFormatsElapsedRemaining() {
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 0, duration: nil), "00:00.00 / --:--")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 1.234, duration: 10), "00:01.23 / 00:08.77")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 61.25, duration: 3_599.5), "01:01.25 / 58:58.25")
        XCTAssertEqual(
            WindowsAudioPlaybackDisplay.text(position: .greatestFiniteMagnitude, duration: nil), "--:--.-- / --:--"
        )
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: .infinity, duration: 1), "--:--.-- / 00:00.00")
    }
}
#endif
