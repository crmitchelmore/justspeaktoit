#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

/// Read aloud keeps its record the active owner while segments are
/// synthesised and between them, so Pause and Stop stay available until the
/// speech ends, and nothing queued behind a Stop can play.
final class WindowsAudioPlaybackSpeechTests: XCTestCase {
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

    func testSpeech_StaysActiveWhileSynthesisedAndBetweenSegments() async throws {
        let id = UUID()
        let speech = try controller.beginSpeech(recordID: id)
        let synthesising = await settledDisplay()
        XCTAssertEqual(synthesising?.recordID, id)
        XCTAssertEqual(synthesising?.state, .preparing, "Stop must be available before the first segment")
        let (first, handle) = try await segment(speech)
        handle.complete(.init(status: .finished, played: 1))
        _ = try await first.value
        let between = await settledDisplay()
        XCTAssertEqual(between?.state, .preparing, "between segments the record must stay active, not idle")
        XCTAssertEqual(controller.activity, .init(recordID: id, state: .preparing))
        let (second, next) = try await segment(speech)
        next.complete(.init(status: .finished, played: 1))
        _ = try await second.value
        controller.endSpeech(speech)
        let ended = await settledDisplay()
        XCTAssertEqual(ended?.state, .idle)
        XCTAssertNil(controller.activity)
        XCTAssertTrue(recorder.statuses.isEmpty, "Read aloud reports its own outcome")
    }

    func testSpeech_ReplacesPlaybackAtTheClickWithoutReportingAStop() async throws {
        let id = UUID()
        try controller.play(recordID: id, path: "history.wav", knownDuration: 2)
        await playbackEventually { self.backend.handles.first?.counts.started == 1 }
        let history = try XCTUnwrap(backend.handles.first)
        let speech = try controller.beginSpeech(recordID: id)
        await playbackEventually { history.counts.cancelled == 1 && self.controller.pendingReleaseCount == 0 }
        let shown = await settledDisplay()
        XCTAssertEqual(shown?.state, .preparing)
        XCTAssertEqual(controller.activity, .init(recordID: id, state: .preparing))
        XCTAssertTrue(recorder.statuses.isEmpty)
        controller.endSpeech(speech)
    }

    /// The user's Stop ends speech while it is synthesised or playing, and
    /// refuses every segment still queued behind it.
    func testStop_EndsSpeechAndRefusesItsQueuedSegments() async throws {
        let id = UUID()
        let synthesising = try controller.beginSpeech(recordID: id)
        controller.stop(announcing: true)
        let stopped = await settledDisplay()
        XCTAssertEqual(stopped?.state, .idle)
        XCTAssertNil(controller.activity)
        await assertRefused(synthesising)

        let playing = try controller.beginSpeech(recordID: id)
        let (segment, handle) = try await segment(playing)
        controller.stop(announcing: true)
        await assertCancelled(segment)
        XCTAssertEqual(handle.counts.cancelled, 1)
        let ended = await settledDisplay()
        XCTAssertEqual(ended?.state, .idle, "the stopped segment's release must not bring speech back")
        await assertRefused(playing)
        XCTAssertTrue(recorder.statuses.isEmpty, "Read aloud reports its own stop")
    }

    func testAnotherRowCaptureAndOtherPlayback_EndSpeech() async throws {
        let id = UUID()
        let kept = try controller.beginSpeech(recordID: id)
        controller.stop(unless: id)
        XCTAssertEqual(controller.activity, .init(recordID: id, state: .preparing), "its own row keeps the speech")
        controller.stop(unless: UUID())
        XCTAssertNil(controller.activity)
        await assertRefused(kept)

        let captured = try controller.beginSpeech(recordID: id)
        try await controller.stopAndWait()
        XCTAssertNil(controller.activity)
        await assertRefused(captured)

        let replaced = try controller.beginSpeech(recordID: id)
        try controller.play(recordID: id, path: "history.wav", knownDuration: 1)
        await playbackEventually { self.backend.handles.count == 1 }
        await assertRefused(replaced)

        let older = try controller.beginSpeech(recordID: id)
        let newer = try controller.beginSpeech(recordID: id)
        await playbackEventually { self.controller.pendingReleaseCount == 0 }
        controller.endSpeech(older)
        XCTAssertEqual(controller.activity, .init(recordID: id, state: .preparing), "an older speech ended a newer one")
        await assertRefused(older)
        controller.endSpeech(newer)
        let ended = await settledDisplay()
        XCTAssertEqual(ended?.state, .idle)
    }

    /// The window resets its controls on every row change, and a quick
    /// A→B→A can reach the host as A alone. Its speech, or a paused run, is
    /// then presented again rather than left looking idle with Stop disabled.
    func testReselectingTheActiveRow_PresentsItsStateAgain() async throws {
        let id = UUID()
        let speech = try controller.beginSpeech(recordID: id)
        _ = await settledDisplay()
        var before = recorder.displays.count
        controller.stop(unless: id)
        let again = await settledDisplay()
        XCTAssertGreaterThan(recorder.displays.count, before)
        XCTAssertEqual(again?.state, .preparing)
        controller.endSpeech(speech)

        try controller.play(recordID: id, path: "history.wav", knownDuration: 1)
        await playbackEventually { self.backend.handles.first?.counts.started == 1 }
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { self.recorder.displays.last?.state == .paused }
        _ = await settledDisplay()
        before = recorder.displays.count
        controller.stop(unless: id)
        let paused = await settledDisplay()
        XCTAssertGreaterThan(recorder.displays.count, before)
        XCTAssertEqual(paused?.state, .paused)
    }

    /// Pausing while a segment is synthesised pauses the speech: its next
    /// segment starts paused, never heard until the user resumes.
    func testPausedSpeech_StartsItsNextSegmentPausedWithoutSound() async throws {
        let id = UUID()
        let speech = try controller.beginSpeech(recordID: id)
        XCTAssertTrue(controller.togglePause(recordID: id))
        XCTAssertFalse(controller.togglePause(recordID: UUID()))
        let paused = await settledDisplay()
        XCTAssertEqual(paused?.state, .paused)
        let (segment, handle) = try await segment(speech)
        XCTAssertEqual(handle.counts.pausedBeforeStart, 1, "the segment was audible before the user resumed")
        XCTAssertEqual(controller.activity?.state, .paused)
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { handle.counts.resumed == 1 }
        handle.complete(.init(status: .finished, played: 1))
        _ = try await segment.value
        let between = await settledDisplay()
        XCTAssertEqual(between?.state, .preparing, "resumed speech prepares its next segment unpaused")
        controller.endSpeech(speech)
    }

    func testSegmentReleaseFailure_IsReportedWhileSpeechStaysShown() async throws {
        let id = UUID()
        let speech = try controller.beginSpeech(recordID: id)
        backend.enqueue(PlaybackTestPlan(destroyFailures: 1))
        let (segment, handle) = try await segment(speech)
        handle.complete(.init(status: .finished, played: 1))
        do {
            _ = try await segment.value
            XCTFail("A failed release returned success")
        } catch let error as WindowsAudioPlaybackError {
            XCTAssertEqual(error.message, "Injected release failure")
        }
        await playbackEventually { !self.recorder.statuses.isEmpty }
        XCTAssertEqual(recorder.statuses, ["Playback could not close: Injected release failure"])
        let shown = await settledDisplay()
        XCTAssertEqual(shown?.state, .preparing)
        controller.endSpeech(speech)
    }

    func testPauseRequestedWhileOpening_IsAppliedBeforeStart() async throws {
        let gate = PlaybackTestGate(), id = UUID()
        backend.enqueue(PlaybackTestPlan(openGate: gate))
        try controller.play(recordID: id, path: "slow.wav", knownDuration: 1)
        await playbackEventually { gate.entered }
        XCTAssertTrue(controller.togglePause(recordID: id))
        gate.open()
        let handle = try XCTUnwrap(backend.handles.first)
        await playbackEventually { handle.counts.started == 1 }
        XCTAssertEqual(handle.counts.pausedBeforeStart, 1)
        await playbackEventually { self.recorder.displays.last?.state == .paused }
    }

    private func segment(
        _ speech: WindowsAudioPlaybackController.Speech
    ) async throws -> (Task<TimeInterval, Error>, PlaybackTestHandle) {
        // A path of its own, so another playback's asynchronous open is never mistaken for it.
        let path = "segment-\(UUID().uuidString).wav"
        let owned = try XCTUnwrap(controller)
        let task = Task { try await owned.playToCompletion(speech, path: path) }
        await playbackEventually { self.backend.handles.contains { $0.path == path } }
        let handle = try XCTUnwrap(backend.handles.first { $0.path == path })
        await playbackEventually { handle.counts.started == 1 }
        return (task, handle)
    }

    /// What the window shows once delivery has caught up with the controller.
    private func settledDisplay() async -> WindowsAudioPlaybackDisplay? {
        await playbackEventually {
            self.recorder.displays.last.map { self.controller.isCurrent(revision: $0.revision) } ?? false
        }
        return recorder.displays.last
    }

    private func assertRefused(
        _ speech: WindowsAudioPlaybackController.Speech, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let count = backend.handles.count
        do {
            _ = try await controller.playToCompletion(speech, path: "queued.wav")
            XCTFail("A segment of an ended speech played", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(backend.handles.count, count, "a refused segment opened its file", file: file, line: line)
    }

    private func assertCancelled(
        _ task: Task<TimeInterval, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("An interrupted segment returned success", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
    }
}
#endif
