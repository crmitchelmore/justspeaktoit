#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

/// Awaited playback shares the one audible output with History playback.
final class WindowsAudioPlaybackCompletionTests: XCTestCase {
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

    private func awaited(_ id: UUID = UUID()) async throws -> (Task<TimeInterval, Error>, PlaybackTestHandle) {
        let count = backend.handles.count
        let owned = try XCTUnwrap(controller)
        let task = Task { try await owned.playToCompletion(recordID: id, path: "speech.wav") }
        await playbackEventually { self.backend.handles.count > count }
        let handle = try XCTUnwrap(backend.handles.last)
        await playbackEventually { handle.counts.started == 1 }
        return (task, handle)
    }

    func testFinishedRun_ReturnsRenderedSecondsAfterReleaseWithoutItsOwnStatus() async throws {
        let id = UUID()
        let (task, handle) = try await awaited(id)
        XCTAssertEqual(controller.activity?.recordID, id)
        handle.complete(.init(status: .finished, played: 1.25))
        let played = try await task.value
        XCTAssertEqual(played, 1.25)
        XCTAssertEqual(handle.counts.destroyed, 1, "the file is released before the caller resumes")
        XCTAssertEqual(controller.pendingReleaseCount, 0)
        await playbackEventually { self.recorder.displays.last?.state == .idle }
        XCTAssertTrue(recorder.statuses.isEmpty, "the awaiting caller reports its own outcome")
    }

    func testStopReplacementAndCloseEndAnAwaitedRunAsCancelled() async throws {
        let (stopped, _) = try await awaited()
        controller.stop()
        await assertCancelled(stopped)

        let (replaced, _) = try await awaited()
        try controller.play(recordID: UUID(), path: "history.wav", knownDuration: 1)
        await assertCancelled(replaced)

        let (closing, _) = try await awaited()
        backend.handles.forEach { $0.acknowledgeQuiet() }
        try await controller.close()
        await assertCancelled(closing)
    }

    func testCancellingTheCallerStopsItsRunEvenBeforeAdmission() async throws {
        let (task, handle) = try await awaited()
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(handle.counts.cancelled, 1)
        await playbackEventually { self.controller.pendingReleaseCount == 0 }

        let owned = try XCTUnwrap(controller)
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await owned.playToCompletion(recordID: UUID(), path: "early.wav")
        }
        await assertCancelled(early)
        await playbackEventually { self.controller.pendingReleaseCount == 0 }
        XCTAssertNil(controller.activity)
    }

    func testFailedPlaybackAndReleaseAreReportedToTheCaller() async throws {
        backend.enqueue(PlaybackTestPlan(startFailure: "No endpoint"))
        let owned = try XCTUnwrap(controller)
        do {
            _ = try await owned.playToCompletion(recordID: UUID(), path: "failed.wav")
            XCTFail("A failed start returned success")
        } catch let error as WindowsAudioPlaybackError {
            XCTAssertEqual(error.message, "No endpoint")
        }
        backend.enqueue(PlaybackTestPlan(destroyFailures: 1))
        let (task, handle) = try await awaited()
        handle.complete(.init(status: .finished, played: 1))
        do {
            _ = try await task.value
            XCTFail("A failed release returned success")
        } catch let error as WindowsAudioPlaybackError {
            XCTAssertEqual(error.message, "Injected release failure")
        }
        XCTAssertEqual(controller.pendingReleaseCount, 1, "the unreleased job stays owned")
    }

    func testPauseActsOnAnAwaitedRunLikeAnyPlaybackOfItsRecord() async throws {
        let id = UUID()
        let (task, handle) = try await awaited(id)
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { handle.counts.paused == 1 }
        XCTAssertTrue(controller.togglePause(recordID: id))
        await playbackEventually { handle.counts.resumed == 1 }
        handle.complete(.init(status: .finished, played: 0.5))
        _ = try await task.value
    }

    private func assertCancelled(
        _ task: Task<TimeInterval, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("An interrupted run returned success", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
    }
}
#endif
