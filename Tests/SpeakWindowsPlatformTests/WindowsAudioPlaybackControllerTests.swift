#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

/// Ownership, generation and presentation rules of the History playback
/// controller against an injected engine; no speaker or native job involved.
final class WindowsAudioPlaybackControllerTests: XCTestCase {
    private var backend = FakePlaybackBackend()
    private var recorder = PresenterRecorder()
    private var controller: WindowsAudioPlaybackController?

    override func setUp() {
        super.setUp()
        backend = FakePlaybackBackend()
        recorder = PresenterRecorder()
        controller = WindowsAudioPlaybackController(
            backend: backend, presenter: recorder.presenter, progressInterval: .milliseconds(5)
        )
    }

    override func tearDown() async throws {
        backend.openAllGates()
        await controller?.close()
        controller = nil
        try await super.tearDown()
    }

    func testPlay_PresentsPreparingThenOnlyAcknowledgedChanges() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 1.5)
        let handle = try XCTUnwrap(backend.handles.last)
        XCTAssertEqual(handle.counts.started, 1)
        XCTAssertEqual(recorder.displays.first, .init(recordID: record, state: .preparing, text: "00:00.00 / 00:01.50"))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.displays.count, 1, "An unchanged snapshot must not be re-presented")
        handle.set(state: .playing, position: 0.25)
        await settle({ self.recorder.displays.last?.state == .playing }, "Playing was never presented")
        XCTAssertEqual(recorder.displays.last?.text, "00:00.25 / 00:01.25")
        XCTAssertEqual(controller.activity, .init(recordID: record, state: .playing))
        // The container's own duration outranks the record metadata once known.
        handle.set(state: .playing, position: 0.25, duration: 0.5)
        await settle({ self.recorder.displays.last?.text == "00:00.25 / 00:00.25" }, "Native duration was not used")
        handle.set(state: .paused, position: 0.25, duration: 0.5)
        await settle({ self.recorder.displays.last?.state == .paused }, "Paused was never presented")
        XCTAssertTrue(recorder.statuses.isEmpty, "Pause and progress never touch the status line")
    }

    func testImmediateCompletionInsideStart_EndsIdleExactlyOnce() async throws {
        let controller = try XCTUnwrap(controller)
        backend.completeOnStart = .init(status: .finished, played: 1.5)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 1.5)
        let handle = try XCTUnwrap(backend.handles.last)
        await settle({ handle.counts.destroyed == 1 && controller.pendingReleaseCount == 0 }, "Release never finished")
        XCTAssertNil(controller.activity)
        XCTAssertEqual(recorder.displays.last, .init(recordID: record, state: .idle, text: "00:00.00 / 00:01.50"))
        XCTAssertEqual(recorder.statuses, ["Playback finished."])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(recorder.displays.count, 2, "No sampler may present after the run ended")
    }

    func testStop_ResetsToZeroImmediatelyAndReleasesInTheBackground() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 2)
        let handle = try XCTUnwrap(backend.handles.last)
        handle.set(state: .playing, position: 0.7)
        await settle({ self.recorder.displays.last?.state == .playing }, "Playing was never presented")
        handle.gate = DispatchSemaphore(value: 0) // Codec teardown is slow.
        controller.stop()
        XCTAssertEqual(handle.counts.cancelled, 1, "Stop cancels audibly before any join")
        XCTAssertEqual(recorder.displays.last, .init(recordID: record, state: .idle, text: "00:00.00 / 00:02.00"))
        XCTAssertEqual(recorder.statuses, ["Playback stopped."])
        XCTAssertNil(controller.activity)
        XCTAssertEqual(controller.pendingReleaseCount, 1)
        XCTAssertEqual(handle.counts.destroyed, 0, "The join must not run on the caller")
        handle.gate?.signal()
        await settle({ handle.counts.destroyed == 1 && controller.pendingReleaseCount == 0 }, "Release never finished")
        XCTAssertEqual(recorder.statuses, ["Playback stopped."], "The cancelled completion of a stopped run is silent")
    }

    func testStaleCompletionOfAReplacedRun_NeverClearsTheNewRun() async throws {
        let controller = try XCTUnwrap(controller)
        let first = UUID(), second = UUID()
        backend.gateNextHandle = DispatchSemaphore(value: 0)
        try controller.play(recordID: first, path: "C:\\history\\a.wav", knownDuration: 1)
        let old = try XCTUnwrap(backend.handles.last)
        try controller.play(recordID: second, path: "C:\\history\\b.wav", knownDuration: 3)
        let new = try XCTUnwrap(backend.handles.last)
        XCTAssertEqual(old.counts.cancelled, 1)
        XCTAssertEqual(controller.activity, .init(recordID: second, state: .preparing))
        new.set(state: .playing, position: 1)
        await settle({ self.recorder.displays.last?.state == .playing }, "Playing was never presented")
        // The old run's cancelled completion arrives late, while its release is still blocked.
        old.complete(.init(status: .cancelled, played: 0.4))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(recorder.displays.last, .init(recordID: second, state: .playing, text: "00:01.00 / 00:02.00"))
        XCTAssertTrue(recorder.statuses.isEmpty)
        XCTAssertEqual(controller.activity, .init(recordID: second, state: .playing))
        old.gate?.signal()
        await settle({ old.counts.destroyed == 1 && controller.pendingReleaseCount == 1 }, "Old run not released")
    }

    func testRapidSwitching_KeepsOneOwnerAndBoundedReleases() async throws {
        let controller = try XCTUnwrap(controller)
        var records: [UUID] = []
        for index in 0..<3 {
            backend.gateNextHandle = DispatchSemaphore(value: 0)
            let record = UUID()
            records.append(record)
            try controller.play(recordID: record, path: "C:\\history\\\(index).wav", knownDuration: 1)
        }
        XCTAssertEqual(backend.handles.count, 3)
        XCTAssertEqual(controller.activity?.recordID, records[2])
        XCTAssertEqual(backend.handles.map { $0.counts.cancelled }, [1, 1, 0])
        XCTAssertEqual(controller.pendingReleaseCount, 3)
        backend.openAllGates()
        await controller.close()
        XCTAssertEqual(backend.handles.map { $0.counts.destroyed }, [1, 1, 1])
        XCTAssertEqual(controller.pendingReleaseCount, 0)
        XCTAssertNil(controller.activity)
        XCTAssertThrowsError(try controller.play(recordID: UUID(), path: "C:\\late.wav", knownDuration: nil))
    }

    func testStopDuringPrepare_CancelsWithoutAnExtraCompletionReport() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: nil)
        let handle = try XCTUnwrap(backend.handles.last)
        XCTAssertEqual(handle.snapshot().state, .preparing)
        controller.stop()
        XCTAssertEqual(handle.counts.cancelled, 1)
        XCTAssertEqual(recorder.displays.last, .init(recordID: record, state: .idle, text: "00:00.00 / --:--"))
        await settle({ handle.counts.destroyed == 1 && controller.pendingReleaseCount == 0 }, "Release never finished")
        XCTAssertEqual(recorder.statuses, ["Playback stopped."])
        XCTAssertEqual(recorder.displays.count, 2)
    }

    func testFailedCompletion_ReportsTheErrorAndEndsIdle() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 4)
        let handle = try XCTUnwrap(backend.handles.last)
        let reason = "No active audio output device is available (HRESULT 0x80070490)."
        handle.complete(.init(status: .failed(reason), played: 0))
        await settle({ handle.counts.destroyed == 1 }, "The failed run was not released")
        XCTAssertEqual(recorder.statuses, ["Playback failed: \(reason)"])
        XCTAssertEqual(recorder.displays.last, .init(recordID: record, state: .idle, text: "00:00.00 / 00:04.00"))
        XCTAssertNil(controller.activity)
    }

    func testTogglePause_FollowsTheAcknowledgedStateAndIgnoresOtherRecords() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        XCTAssertFalse(controller.togglePause(recordID: record))
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 1)
        let handle = try XCTUnwrap(backend.handles.last)
        XCTAssertTrue(controller.togglePause(recordID: record), "Preparing pauses the first frame")
        XCTAssertEqual(handle.counts.paused, 1)
        // Until the engine acknowledges, a repeated toggle repeats the pause
        // (idempotent natively) instead of guessing that it should resume.
        XCTAssertTrue(controller.togglePause(recordID: record))
        XCTAssertEqual(handle.counts.paused, 2)
        XCTAssertEqual(handle.counts.resumed, 0)
        handle.set(state: .paused, position: 0)
        XCTAssertTrue(controller.togglePause(recordID: record))
        XCTAssertEqual(handle.counts.resumed, 1)
        handle.set(state: .playing, position: 0.5)
        XCTAssertTrue(controller.togglePause(recordID: record))
        XCTAssertEqual(handle.counts.paused, 3)
        XCTAssertFalse(controller.togglePause(recordID: UUID()))
        XCTAssertEqual(handle.counts.paused, 3)
        XCTAssertEqual(handle.counts.resumed, 1)
    }

    func testStartFailure_ThrowsResetsTheDisplayAndReleasesTheHandle() async throws {
        let controller = try XCTUnwrap(controller)
        backend.startFailure = WindowsAudioPlaybackError("Audio playback was already started or cancelled.")
        let record = UUID()
        XCTAssertThrowsError(try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: nil))
        let handle = try XCTUnwrap(backend.handles.last)
        XCTAssertNil(controller.activity)
        XCTAssertEqual(recorder.displays.last, .init(recordID: record, state: .idle, text: "00:00.00 / --:--"))
        await settle({ handle.counts.destroyed == 1 && controller.pendingReleaseCount == 0 }, "Release never finished")
    }

    func testSamplerStopsAndHandlesAreReleasedAfterClose() async throws {
        let controller = try XCTUnwrap(controller)
        try controller.play(recordID: UUID(), path: "C:\\history\\a.wav", knownDuration: 1)
        weak let released = backend.handles.last
        try XCTUnwrap(released).set(state: .playing, position: 0.1)
        await settle({ self.recorder.displays.last?.state == .playing }, "Playing was never presented")
        await controller.close()
        let presented = recorder.displays.count
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(recorder.displays.count, presented, "No sampler survives close")
        backend.forgetHandles()
        XCTAssertNil(released, "The controller must not retain a released handle")
    }

    func testStopUnlessSameRecord_KeepsTheActiveRecordPlaying() async throws {
        let controller = try XCTUnwrap(controller)
        let record = UUID()
        try controller.play(recordID: record, path: "C:\\history\\a.wav", knownDuration: 1)
        controller.stop(unless: record)
        XCTAssertEqual(controller.activity?.recordID, record)
        controller.stop(unless: UUID())
        XCTAssertNil(controller.activity)
    }

    func testDisplayText_FormatsElapsedAndRemainingHonestly() {
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 0, duration: nil), "00:00.00 / --:--")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 1.234, duration: 10), "00:01.23 / 00:08.77")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 11, duration: 10), "00:11.00 / 00:00.00")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: 61.25, duration: 3_599.5), "01:01.25 / 58:58.25")
        XCTAssertEqual(WindowsAudioPlaybackDisplay.text(position: .infinity, duration: 1), "--:--.-- / 00:00.00")
    }

    /// Polls a condition with a firm deadline and records a failure at the
    /// call site when it never holds.
    private func settle(
        _ condition: @escaping () -> Bool, _ message: String, timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !condition() { XCTFail(message, file: file, line: line) }
    }
}

private final class FakePlaybackHandle: WindowsAudioPlaybackHandle, @unchecked Sendable {
    struct Counts: Equatable { var started = 0, paused = 0, resumed = 0, cancelled = 0, destroyed = 0 }

    private let lock = NSLock()
    private let completion: @Sendable (WindowsAudioPlaybackCompletion) -> Void
    private var state = WindowsAudioPlaybackState.preparing
    private var position: TimeInterval = 0
    private var duration: TimeInterval?
    private var completed = false
    private var recorded = Counts()
    var completeOnStart: WindowsAudioPlaybackCompletion?
    var startFailure: Error?
    var gate: DispatchSemaphore?

    init(duration: TimeInterval?, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void) {
        self.duration = duration
        self.completion = completion
    }

    var counts: Counts { lock.withLock { recorded } }

    func set(state: WindowsAudioPlaybackState, position: TimeInterval, duration: TimeInterval? = nil) {
        lock.withLock {
            self.state = state
            self.position = position
            if let duration { self.duration = duration }
        }
    }

    /// Delivers the terminal completion exactly once, like the native worker.
    func complete(_ value: WindowsAudioPlaybackCompletion) {
        let first: Bool = lock.withLock {
            guard !completed else { return false }
            completed = true
            state = .ended
            return true
        }
        if first { completion(value) }
    }

    func start() throws {
        lock.withLock { recorded.started += 1 }
        if let startFailure { throw startFailure }
        if let completeOnStart { complete(completeOnStart) }
    }

    func pause() { lock.withLock { recorded.paused += 1 } }

    func resume() { lock.withLock { recorded.resumed += 1 } }

    func cancel() { lock.withLock { recorded.cancelled += 1 } }

    func snapshot() -> WindowsAudioPlaybackSnapshot {
        lock.withLock { WindowsAudioPlaybackSnapshot(state: state, position: position, duration: duration) }
    }

    /// Blocks on the gate like a slow codec teardown, then joins: a run that
    /// has not completed yet completes as cancelled during the join.
    func destroy() throws {
        gate?.wait()
        complete(WindowsAudioPlaybackCompletion(status: .cancelled, played: snapshot().position))
        lock.withLock { recorded.destroyed += 1 }
    }
}

private final class FakePlaybackBackend: WindowsAudioPlaybackBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakePlaybackHandle] = []
    var completeOnStart: WindowsAudioPlaybackCompletion?
    var startFailure: Error?
    var gateNextHandle: DispatchSemaphore?

    var handles: [FakePlaybackHandle] { lock.withLock { opened } }

    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        let handle = FakePlaybackHandle(duration: nil, completion: completion)
        lock.withLock {
            handle.completeOnStart = completeOnStart
            handle.startFailure = startFailure
            handle.gate = gateNextHandle
            gateNextHandle = nil
            opened.append(handle)
        }
        return handle
    }

    func openAllGates() { handles.forEach { $0.gate?.signal() } }

    func forgetHandles() { lock.withLock { opened.removeAll() } }
}

private final class PresenterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [WindowsAudioPlaybackDisplay] = []
    private var reported: [String] = []

    var displays: [WindowsAudioPlaybackDisplay] { lock.withLock { shown } }
    var statuses: [String] { lock.withLock { reported } }

    var presenter: WindowsAudioPlaybackPresenter {
        WindowsAudioPlaybackPresenter(
            show: { [self] display in lock.withLock { shown.append(display) } },
            status: { [self] message in lock.withLock { reported.append(message) } }
        )
    }
}
#endif
