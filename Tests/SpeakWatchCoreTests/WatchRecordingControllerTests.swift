import Foundation
@testable import SpeakWatchCore
import XCTest

/// The watch recorder's lifecycle against a fake recorder: delegate detach,
/// the single exit path, start/finalisation overlap and recovery retries.
@MainActor
final class WatchRecordingControllerTests: XCTestCase {
    private final class FakeRecorder: WatchCaptureRecorder {
        var currentTime: TimeInterval = 3
        var recordSucceeds = true
        private(set) var events: [String] = []
        var onUnexpectedEnd: (@MainActor @Sendable (WatchRecordingEndReason) async -> Void)? {
            didSet { events.append(onUnexpectedEnd == nil ? "detach" : "attach") }
        }

        func record() -> Bool {
            events.append("record")
            return recordSucceeds
        }

        func stop() { events.append("stop") }
    }

    /// Suspends callers until opened.
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private final class FakeHost: WatchRecordingHost {
        var recordSucceeds = true
        var enqueueSucceeds = true
        var inspection = WatchAudioInspection(isPlayable: true, duration: 3)
        var permissionGate: Gate?
        var inspectionGate: Gate?
        private(set) var recorders: [FakeRecorder] = []
        private(set) var runtime: [String] = []
        private(set) var permissionRequests = 0
        private(set) var inspections = 0
        private(set) var queued: [WatchFinishedRecording] = []

        func requestRecordPermission() async -> Bool {
            permissionRequests += 1
            await permissionGate?.wait()
            return true
        }

        func beginRuntime() throws { runtime.append("begin") }
        func endRuntime() { runtime.append("end") }

        func makeRecorder(writingTo url: URL) throws -> FakeRecorder {
            try Data("audio".utf8).write(to: url)
            let recorder = FakeRecorder()
            recorder.recordSucceeds = recordSucceeds
            recorders.append(recorder)
            return recorder
        }

        func inspectAudio(at url: URL) async -> WatchAudioInspection {
            inspections += 1
            await inspectionGate?.wait()
            return inspection
        }

        func isQueued(captureID: UUID) -> Bool {
            queued.contains { $0.id == captureID }
        }

        func enqueue(_ recording: WatchFinishedRecording) -> Bool {
            guard enqueueSucceeds else { return false }
            queued.append(recording)
            return true
        }
    }

    private var directory: URL!
    private var host: FakeHost!
    private var registry: WatchActiveCaptureRegistry!
    private var controller: WatchRecordingController<FakeHost>!
    private var statuses: [WatchRecorderStatus] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-recorder-\(UUID().uuidString)", isDirectory: true)
        host = FakeHost()
        registry = WatchActiveCaptureRegistry(fileURL: directory.appendingPathComponent("active-capture.json"))
        controller = WatchRecordingController(host: host, registry: registry, capturesDirectory: directory)
        controller.onStatusChange = { [unowned self] in self.statuses.append($0) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lets other main-actor tasks run until `condition` holds.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition never became true")
    }

    func testStop_detachesTheRecorderBeforeStoppingIt_andQueuesTheCapture() async throws {
        await controller.start()
        let recorder = try XCTUnwrap(host.recorders.first)
        let capture = try XCTUnwrap(registry.load())
        XCTAssertNotNil(recorder.onUnexpectedEnd)
        XCTAssertTrue(controller.status.isRecording)

        await controller.stop()

        XCTAssertEqual(recorder.events, ["attach", "record", "detach", "stop"])
        XCTAssertNil(recorder.onUnexpectedEnd)
        XCTAssertEqual(host.queued.map(\.id), [capture.id])
        XCTAssertEqual(host.queued.first?.duration, 3)
        XCTAssertEqual(host.runtime, ["begin", "end"])
        XCTAssertNil(registry.load())
        XCTAssertFalse(controller.status.isRecording)
        guard case .idle = controller.lifecycle.activity else { return XCTFail("Not idle after finalising") }
        // The complication never sees a recording without its start time.
        XCTAssertFalse(statuses.contains { $0.isRecording && $0.startedAt == nil })
        XCTAssertEqual(statuses.map(\.isRecording), [true, false])
    }

    func testCallbackFromAReleasedRecorder_neverEndsTheNextRecording() async throws {
        await controller.start()
        let stale = try XCTUnwrap(host.recorders.first?.onUnexpectedEnd)
        await controller.stop()
        await controller.start()

        await stale(.runtimeInvalidated(reason: nil))

        XCTAssertTrue(controller.status.isRecording)
        XCTAssertEqual(host.recorders.count, 2)
        XCTAssertEqual(host.queued.count, 1)
    }

    func testUnexpectedEnd_fromTheOwnedRecorder_finishesWithItsReason() async throws {
        await controller.start()
        let recorder = try XCTUnwrap(host.recorders.first)

        await recorder.onUnexpectedEnd?(.interrupted)

        XCTAssertEqual(recorder.events, ["attach", "record", "detach", "stop"])
        XCTAssertEqual(host.queued.count, 1)
        XCTAssertEqual(controller.status.lastError, "Recording was interrupted. Sending what was captured.")
        XCTAssertFalse(controller.status.isRecording)
    }

    func testStartDuringFinalisation_overlapsIt_andRecordsOnceTheMarkerIsReconciled() async throws {
        let gate = Gate()
        host.inspectionGate = gate
        await controller.start()
        let stopping = Task { await controller.stop() }
        await settle { host.inspections == 1 }

        let starting = Task { await controller.start() }
        await settle { controller.lifecycle.isStartInFlight }

        // The legitimate overlap: a start waits on the previous finalisation.
        XCTAssertNotNil(controller.lifecycle.finalisation)
        XCTAssertNotNil(registry.load(), "The marker stays until finalisation reconciles it")
        XCTAssertEqual(host.recorders.count, 1)

        gate.open()
        await stopping.value
        await starting.value

        XCTAssertEqual(host.queued.count, 1)
        XCTAssertEqual(host.recorders.count, 2)
        XCTAssertTrue(controller.status.isRecording)
        XCTAssertNil(controller.status.lastError)
    }

    func testSecondStart_whileTheFirstAwaitsPermission_isIgnored() async {
        let gate = Gate()
        host.permissionGate = gate
        let first = Task { await controller.start() }
        await settle { host.permissionRequests == 1 }

        await controller.start()
        XCTAssertEqual(host.permissionRequests, 1)

        gate.open()
        await first.value
        XCTAssertEqual(host.recorders.count, 1)
        XCTAssertTrue(controller.status.isRecording)
    }

    func testRecordFailure_finalisesInsideStart_andReleasesEverything() async throws {
        host.recordSucceeds = false
        host.inspection = .unplayable

        await controller.start()

        let recorder = try XCTUnwrap(host.recorders.first)
        XCTAssertEqual(recorder.events, ["attach", "record", "detach", "stop"])
        XCTAssertEqual(controller.status.lastError, WatchRecorderError.failedToStart.localizedDescription)
        XCTAssertFalse(controller.status.isRecording)
        XCTAssertFalse(controller.lifecycle.isStartInFlight)
        XCTAssertEqual(host.runtime, ["begin", "end"])
        XCTAssertTrue(host.queued.isEmpty)
        XCTAssertNil(registry.load())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.allSatisfy { !$0.hasSuffix(".m4a") }, "Discarded audio must be removed: \(files)")
    }

    func testRecovery_queuesAnInterruptedCaptureOnce() async throws {
        let capture = WatchActiveCapture(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.persist(capture)
        try Data("audio".utf8).write(to: controller.fileURL(for: capture.id))

        await controller.recoverInterruptedCapture()
        await controller.recoverInterruptedCapture()

        XCTAssertEqual(host.queued.map(\.id), [capture.id])
        XCTAssertEqual(host.queued.first?.createdAt, capture.startedAt)
        XCTAssertNil(registry.load())
        XCTAssertEqual(
            controller.status.lastError,
            "Recording ended while the watch app was unavailable."
        )
    }

    func testFailedEnqueue_keepsTheMarker_andTheNextStartRecoversItFirst() async throws {
        host.enqueueSucceeds = false
        await controller.start()
        let capture = try XCTUnwrap(registry.load())
        await controller.stop()

        XCTAssertEqual(registry.load(), capture)
        XCTAssertEqual(
            controller.status.lastError,
            "Recording was saved but could not be queued. It will be recovered next time."
        )

        host.enqueueSucceeds = true
        await controller.start()

        XCTAssertEqual(host.queued.map(\.id), [capture.id])
        XCTAssertEqual(host.recorders.count, 2)
        XCTAssertTrue(controller.status.isRecording)
        XCTAssertNotEqual(registry.load()?.id, capture.id)
    }
}
