@preconcurrency import AVFoundation
import Foundation
import SpeakCore

@testable import SpeakApp

// MARK: - Test doubles

/// Cancellation-aware gate: `wait()` suspends until `open()` (or task
/// cancellation) and signals entry so tests can order interleavings.
actor TestGate {
  private var isOpen = false
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    for waiter in enteredWaiters {
      waiter.resume()
    }
    enteredWaiters = []
    guard !isOpen else { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if isOpen || Task.isCancelled {
          continuation.resume()
        } else {
          waiters.append(continuation)
        }
      }
    } onCancel: {
      Task { await self.open() }
    }
  }

  func open() {
    isOpen = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters = []
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }
}

final class MockTranscriber: FluidAudioStreamingTranscribing, @unchecked Sendable {
  private let lock = NSLock()
  private var _processGate: TestGate?
  private var _processError: (any Error)?
  private var _finalText: String
  private var _processedCount = 0
  private var _resetCount = 0
  private var _partialHandler: (@Sendable (String) -> Void)?

  init(finalText: String = "final transcript") {
    _finalText = finalText
  }

  var processGate: TestGate? {
    get { lock.withLock { _processGate } }
    set { lock.withLock { _processGate = newValue } }
  }

  var processError: (any Error)? {
    get { lock.withLock { _processError } }
    set { lock.withLock { _processError = newValue } }
  }

  var processedCount: Int { lock.withLock { _processedCount } }
  var resetCount: Int { lock.withLock { _resetCount } }
  var partialHandler: (@Sendable (String) -> Void)? { lock.withLock { _partialHandler } }

  func resetSession() async {
    lock.withLock { _resetCount += 1 }
  }

  func streamAudio(_ buffer: AVAudioPCMBuffer) async throws {
    if let gate = processGate {
      await gate.wait()
    }
    if let error = processError {
      throw error
    }
    lock.withLock { _processedCount += 1 }
  }

  func finishSession() async throws -> String {
    lock.withLock { _finalText }
  }

  func setPartialTranscriptHandler(_ handler: @escaping @Sendable (String) -> Void) async {
    lock.withLock { _partialHandler = handler }
  }

  func setUtteranceHandler(_ handler: @escaping @Sendable (String) -> Void) async {}
}

@MainActor
final class MockCapture: FluidAudioAudioCapturing {
  private(set) var started = false
  private(set) var stopCount = 0
  private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
    started = true
    self.onBuffer = onBuffer
  }

  func stop() {
    stopCount += 1
    onBuffer = nil
  }

  func emit(_ buffer: AVAudioPCMBuffer) {
    onBuffer?(buffer)
  }
}

@MainActor
final class TranscriberBox {
  private var transcriber: MockTranscriber

  init(_ transcriber: MockTranscriber) {
    self.transcriber = transcriber
  }

  func set(_ transcriber: MockTranscriber) {
    self.transcriber = transcriber
  }

  func take() -> any FluidAudioStreamingTranscribing {
    transcriber
  }
}

@MainActor
final class RecordingDelegate: LiveTranscriptionSessionDelegate {
  private(set) var partials: [String] = []
  private(set) var finished: [TranscriptionResult] = []
  private(set) var failures: [any Error] = []
  private(set) var boundaries: [String] = []

  func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
    partials.append(text)
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didUpdateWith update: LiveTranscriptionUpdate
  ) {}

  func liveTranscriber(_ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult) {
    finished.append(result)
  }

  func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: any Error) {
    failures.append(error)
  }

  func liveTranscriber(
    _ session: any LiveTranscriptionController,
    didDetectUtteranceBoundary utterance: String
  ) {
    boundaries.append(utterance)
  }
}
