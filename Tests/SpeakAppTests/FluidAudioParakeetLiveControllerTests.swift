@preconcurrency import AVFoundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Behavioural tests for issue #715: FluidAudio streaming cancellation and
/// backpressure must be lossless. Covers stale-run interleaving, structured
/// error + drop accounting from the buffer pump, and lossy-transcript marking.
@MainActor
final class FluidAudioParakeetLiveControllerTests: XCTestCase {
  private enum TestError: Error {
    case processing
  }

  // MARK: - Stale-run interleaving

  func testStopDuringModelPreparation_preventsMicrophoneActivation() async throws {
    let gate = TestGate()
    let transcriber = MockTranscriber()
    let capture = MockCapture()
    let harness = makeHarness(
      transcriberProvider: {
        await gate.wait()
        return transcriber
      },
      capture: capture
    )

    let startTask = Task { try await harness.controller.start() }
    await gate.waitUntilEntered()
    await harness.controller.stop()

    let result = await startTask.result
    guard case .failure = result else {
      XCTFail("A start interrupted by stop must throw, not report success")
      return
    }
    XCTAssertFalse(capture.started, "Stop during model preparation must prevent microphone activation")
    XCTAssertFalse(harness.controller.isRunning)
    XCTAssertTrue(harness.delegate.finished.isEmpty)
    XCTAssertTrue(
      harness.delegate.failures.isEmpty,
      "A cancelled start throws to its caller; the delegate gets no terminal outcome"
    )

    // The controller must be reusable for a clean replacement run.
    await gate.open()
    try await harness.controller.start()
    XCTAssertTrue(capture.started)
    XCTAssertTrue(harness.controller.isRunning)
    await harness.controller.stop()
    XCTAssertEqual(harness.delegate.finished.count, 1)
    XCTAssertTrue(harness.delegate.failures.isEmpty)
  }

  func testLateCallbacksFromRetiredRun_doNotAffectReplacement() async throws {
    let capture = MockCapture()
    let first = MockTranscriber(finalText: "first run")
    let second = MockTranscriber(finalText: "second run")
    let box = TranscriberBox(first)
    let harness = makeHarness(transcriberProvider: { box.take() }, capture: capture)

    try await harness.controller.start()
    let stalePartialHandler = first.partialHandler
    await harness.controller.stop()
    XCTAssertEqual(harness.delegate.finished.count, 1)

    box.set(second)
    try await harness.controller.start()
    stalePartialHandler?("stale text from the retired run")
    await drainAsyncWork()
    XCTAssertTrue(
      harness.delegate.partials.isEmpty,
      "A late partial from a retired run must not reach the delegate"
    )
    XCTAssertTrue(harness.controller.isRunning)

    await harness.controller.stop()
    XCTAssertEqual(harness.delegate.finished.count, 2)
    XCTAssertEqual(
      harness.delegate.finished[1].text,
      "second run",
      "The retired run's late callback must not leak into the replacement's transcript"
    )
    XCTAssertTrue(harness.delegate.failures.isEmpty)
  }

  // MARK: - Exactly-once terminal outcome

  func testProcessingFailureConcurrentWithStop_deliversExactlyOneFailureAndNoSuccess() async throws {
    let capture = MockCapture()
    let transcriber = MockTranscriber()
    transcriber.processError = TestError.processing
    let harness = makeHarness(transcriberProvider: { transcriber }, capture: capture)

    try await harness.controller.start()
    capture.emit(Self.makeBuffer())
    await harness.controller.stop()
    await drainAsyncWork()

    XCTAssertEqual(harness.delegate.failures.count, 1, "Exactly one failure must be delivered")
    XCTAssertTrue(harness.delegate.finished.isEmpty, "No success may follow a processing failure")
    XCTAssertFalse(harness.controller.isRunning)
  }

  // MARK: - Buffer pump terminal outcome

  func testBufferPumpFinish_returnsProcessingErrorAndDropAccounting() async throws {
    let pump = FluidAudioBufferPump()
    let gate = TestGate()
    pump.start(
      process: { _ in
        await gate.wait()
        throw TestError.processing
      },
      onError: { _ in }
    )

    // The consumer takes one buffer in flight and blocks on the gate; the
    // queue then saturates deterministically.
    pump.enqueue(Self.makeBuffer())
    await gate.waitUntilEntered()
    let overflow = 5
    for _ in 0..<(FluidAudioBufferPump.bufferCapacity + overflow) {
      pump.enqueue(Self.makeBuffer())
    }

    await gate.open()
    let outcome = await pump.finish()

    XCTAssertEqual(outcome.droppedBufferCount, overflow)
    XCTAssertEqual(
      outcome.droppedAudioSeconds,
      Double(overflow) * 2048.0 / 16_000.0,
      accuracy: 0.001
    )
    XCTAssertEqual(outcome.queuedBufferHighWaterMark, FluidAudioBufferPump.bufferCapacity)
    XCTAssertNotNil(outcome.processingError, "finish() must surface the consumer's terminal error")
    XCTAssertTrue(outcome.isLossy)
  }

  // MARK: - Lossy-transcript marking

  func testSaturatedQueue_marksTranscriptLossyWithDropCounts() async throws {
    let capture = MockCapture()
    let gate = TestGate()
    let transcriber = MockTranscriber(finalText: "lossy run text")
    transcriber.processGate = gate
    let harness = makeHarness(transcriberProvider: { transcriber }, capture: capture)

    try await harness.controller.start()
    capture.emit(Self.makeBuffer())
    await gate.waitUntilEntered()
    let overflow = 3
    for _ in 0..<(FluidAudioBufferPump.bufferCapacity + overflow) {
      capture.emit(Self.makeBuffer())
    }
    await gate.open()
    await harness.controller.stop()

    XCTAssertEqual(harness.delegate.finished.count, 1)
    XCTAssertTrue(harness.delegate.failures.isEmpty)
    let result = try XCTUnwrap(harness.delegate.finished.first)
    XCTAssertEqual(result.text, "lossy run text")

    let payload = try XCTUnwrap(result.rawPayload, "A lossy run must carry an explicit marker")
    let marker = try JSONDecoder().decode(LossyMarker.self, from: Data(payload.utf8))
    XCTAssertTrue(marker.lossyAudio)
    XCTAssertEqual(marker.droppedBufferCount, overflow)
    XCTAssertGreaterThan(marker.droppedAudioSeconds, 0)
    XCTAssertEqual(marker.queuedBufferHighWaterMark, FluidAudioBufferPump.bufferCapacity)
  }

  func testCleanRun_hasNoLossyMarker() async throws {
    let capture = MockCapture()
    let transcriber = MockTranscriber(finalText: "clean run text")
    let harness = makeHarness(transcriberProvider: { transcriber }, capture: capture)

    try await harness.controller.start()
    capture.emit(Self.makeBuffer())
    capture.emit(Self.makeBuffer())
    await harness.controller.stop()

    XCTAssertEqual(harness.delegate.finished.count, 1)
    let result = try XCTUnwrap(harness.delegate.finished.first)
    XCTAssertEqual(result.text, "clean run text")
    XCTAssertNil(result.rawPayload, "A run that preserved all audio must not be marked lossy")
    XCTAssertTrue(harness.delegate.failures.isEmpty)
  }

  // MARK: - Helpers

  private struct LossyMarker: Decodable {
    let provider: String
    let lossyAudio: Bool
    let droppedBufferCount: Int
    let droppedAudioSeconds: Double
    let queuedBufferHighWaterMark: Int
  }

  private struct Harness {
    let controller: FluidAudioParakeetLiveController
    let delegate: RecordingDelegate
  }

  private func makeHarness(
    transcriberProvider: @escaping FluidAudioParakeetLiveController.TranscriberProvider,
    capture: MockCapture
  ) -> Harness {
    let defaults = UserDefaults(suiteName: "fluidaudio-live-tests-\(UUID().uuidString)") ?? .standard
    let settings = AppSettings(defaults: defaults)
    settings.liveStopGracePeriod = 0
    let permissions = PermissionsManager(statusProvider: { _ in .granted })
    let audioDevices = AudioInputDeviceManager(appSettings: settings)
    let modelManager = FluidAudioModelManager(
      modelsDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("fluidaudio-live-tests-\(UUID().uuidString)", isDirectory: true)
    )
    let delegate = RecordingDelegate()
    let controller = FluidAudioParakeetLiveController(
      appSettings: settings,
      permissionsManager: permissions,
      audioDeviceManager: audioDevices,
      modelManager: modelManager,
      transcriberProvider: transcriberProvider,
      captureProvider: { capture }
    )
    controller.delegate = delegate
    return Harness(controller: controller, delegate: delegate)
  }

  private func drainAsyncWork() async {
    for _ in 0..<20 {
      await Task.yield()
    }
  }

  private static func makeBuffer(frames: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else {
      fatalError("Could not allocate test audio buffer")
    }
    buffer.frameLength = frames
    return buffer
  }
}
