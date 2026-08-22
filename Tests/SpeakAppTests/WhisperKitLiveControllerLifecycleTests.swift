import SpeakCore
import XCTest

@testable import SpeakApp

/// Lifecycle tests for issue #713: a WhisperKit start must be cancellable at
/// every suspension before the microphone runs, a retired run must never
/// touch its replacement, and each run gets exactly one terminal outcome.
@MainActor
final class WhisperKitLiveControllerLifecycleTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case stream
    }

    // MARK: - Stop during startup

    func testStopDuringPipelinePreparation_preventsStreamStart() async throws {
        let gate = TestGate()
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make { _, onEvent in
            await gate.wait()
            stream.onEvent = onEvent
            return stream
        }

        let startTask = Task { try await harness.controller.start() }
        await gate.waitUntilEntered()
        await harness.controller.stop()

        let result = await startTask.result
        guard case .failure = result else {
            XCTFail("A start interrupted by stop must throw, not report success")
            return
        }
        XCTAssertEqual(stream.startCount, 0, "Stop during model preparation must prevent capture from starting")
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertTrue(
            harness.delegate.failures.isEmpty,
            "A cancelled start throws to its caller; the delegate gets no terminal outcome"
        )

        // The controller must be reusable for a clean replacement run.
        await gate.open()
        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.controller.isRunning)
        XCTAssertEqual(stream.startCount, 1)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
        XCTAssertTrue(harness.delegate.failures.isEmpty)
    }

    func testStopWhileWaitingForFirstAudio_throwsAndStopsStream() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)

        let startTask = Task { try await harness.controller.start() }
        await stream.waitUntilStarted(after: 0)
        await harness.controller.stop()

        let result = await startTask.result
        guard case .failure(let error) = result else {
            XCTFail("A start interrupted by stop must throw")
            return
        }
        XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionNotRunning)
        XCTAssertGreaterThanOrEqual(stream.stopCount, 1, "The started stream must be stopped on abort")
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertTrue(harness.delegate.failures.isEmpty)
        XCTAssertTrue(stream.tailRequests.isEmpty, "An aborted start has nothing to finalise")

        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.controller.isRunning)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
    }

    func testStartupTimeout_throwsAndReleasesStream() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream, startupTimeout: .milliseconds(50))

        let result = await Task { try await harness.controller.start() }.result
        guard case .failure(let error) = result else {
            XCTFail("A stream that never delivers audio must time out")
            return
        }
        XCTAssertEqual(error as? TranscriptionManagerError, .localLiveStreamingStartupTimedOut)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertTrue(harness.delegate.failures.isEmpty)

        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.controller.isRunning)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
    }

    func testStreamFailureBeforeFirstAudio_throwsWithoutDelegateOutcome() async throws {
        let stream = MockWhisperKitStream()
        stream.startError = TestError.stream
        let harness = WhisperKitLiveHarness.make(stream: stream)

        let result = await Task { try await harness.controller.start() }.result
        guard case .failure(let error) = result else {
            XCTFail("A stream that fails to start must fail the start")
            return
        }
        XCTAssertEqual(error as? TestError, .stream)
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertTrue(harness.delegate.failures.isEmpty)

        stream.startError = nil
        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.controller.isRunning)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
    }

    func testStreamEndingRightAfterFirstAudio_failsStartInsteadOfRunning() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)

        let startTask = Task { try await harness.controller.start() }
        await stream.waitUntilStarted(after: 0)
        // Both land on the main actor before the start path can resume: the
        // audio event resolves the startup wait, then the stream ends.
        stream.emit(.audioArrived)
        stream.endStream()

        let result = await startTask.result
        guard case .failure = result else {
            XCTFail("A stream that ends before the session is running must fail the start")
            return
        }
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertTrue(harness.delegate.failures.isEmpty)

        try await harness.startRunning(with: stream)
        XCTAssertTrue(harness.controller.isRunning)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
    }

    // MARK: - Run isolation

    func testLateEventsFromRetiredRun_doNotAffectReplacement() async throws {
        let first = MockWhisperKitStream()
        first.tailText = " first run"
        let second = MockWhisperKitStream()
        second.tailText = " second run"
        let box = WhisperKitStreamBox(first)
        let harness = WhisperKitLiveHarness.make { _, onEvent in
            let stream = box.take()
            stream.onEvent = onEvent
            return stream
        }

        try await harness.startRunning(with: first)
        let staleHandler = try XCTUnwrap(first.onEvent)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.map(\.text), ["first run"])

        box.set(second)
        try await harness.startRunning(with: second)
        staleHandler(.transcript(WhisperKitTranscriptState(currentText: " stale text from the retired run")))
        staleHandler(.audioArrived)
        await drainWhisperKitAsyncWork()
        XCTAssertTrue(
            harness.delegate.partials.isEmpty,
            "A late event from a retired run must not reach the delegate"
        )
        XCTAssertTrue(harness.controller.isRunning)

        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.map(\.text), ["first run", "second run"])
        XCTAssertEqual(second.tailRequests, [0])
        XCTAssertTrue(harness.delegate.failures.isEmpty)
    }

    func testStartWhileRunning_throwsWithoutDisturbingRun() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        try await harness.startRunning(with: stream)

        do {
            try await harness.controller.start()
            XCTFail("A second start while running must throw")
        } catch {
            XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionAlreadyRunning)
        }
        XCTAssertTrue(harness.controller.isRunning)
        XCTAssertEqual(stream.startCount, 1)
        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.finished.count, 1)
    }

    // MARK: - Exactly-once terminal outcome

    func testStreamFailureMidRun_deliversExactlyOneFailure() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        try await harness.startRunning(with: stream)

        stream.fail(TestError.stream)
        await waitUntilWhisperKit { harness.delegate.failures.count == 1 }

        XCTAssertEqual(harness.delegate.failures.count, 1)
        XCTAssertEqual(harness.delegate.failures.first as? TestError, .stream)
        XCTAssertTrue(harness.delegate.finished.isEmpty, "No success may follow a stream failure")
        XCTAssertFalse(harness.controller.isRunning)
        XCTAssertTrue(stream.tailRequests.isEmpty, "A failed run is not finalised")

        await harness.controller.stop()
        XCTAssertEqual(harness.delegate.failures.count, 1, "A stop after the failure adds no second outcome")
        XCTAssertTrue(harness.delegate.finished.isEmpty)
    }

    func testStreamEndingWithoutErrorMidRun_isReportedAsFailure() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        try await harness.startRunning(with: stream)

        stream.endStream()
        await waitUntilWhisperKit { harness.delegate.failures.count == 1 }

        XCTAssertEqual(harness.delegate.failures.first as? TranscriptionManagerError, .liveSessionNotRunning)
        XCTAssertTrue(harness.delegate.finished.isEmpty)
        XCTAssertFalse(harness.controller.isRunning)
    }

    // MARK: - Request mapping

    func testStreamRequest_mapsStreamingModelAndLanguage() async throws {
        let stream = MockWhisperKitStream()
        var requests: [WhisperKitStreamRequest] = []
        let harness = WhisperKitLiveHarness.make { request, onEvent in
            requests.append(request)
            stream.onEvent = onEvent
            return stream
        }
        harness.controller.configure(language: "en-GB", model: WhisperKitStreamingModel.prefix + "base")

        try await harness.startRunning(with: stream)
        await harness.controller.stop()

        XCTAssertEqual(requests, [WhisperKitStreamRequest(batchModelID: "local/whisperkit/base", language: "en")])
    }

    func testStart_rejectsNonWhisperKitModel() async throws {
        let stream = MockWhisperKitStream()
        let harness = WhisperKitLiveHarness.make(stream: stream)
        harness.controller.configure(language: nil, model: "local/streaming/other")

        do {
            try await harness.controller.start()
            XCTFail("A model outside the WhisperKit streaming namespace must be rejected")
        } catch {
            XCTAssertEqual(error as? TranscriptionManagerError, .invalidLocalStreamingSource("local/streaming/other"))
        }
        XCTAssertEqual(stream.startCount, 0)
        XCTAssertFalse(harness.controller.isRunning)
    }
}
