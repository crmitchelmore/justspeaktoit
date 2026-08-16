@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// The subset of `StreamingEouAsrManager` the live controller drives. A seam
/// so behavioural tests can exercise cancellation and backpressure with
/// delayed model preparation and forced processing errors (issue #715).
protocol FluidAudioStreamingTranscribing: Sendable {
  func resetSession() async
  func streamAudio(_ buffer: AVAudioPCMBuffer) async throws
  func finishSession() async throws -> String
  func setPartialTranscriptHandler(_ handler: @escaping @Sendable (String) -> Void) async
  func setUtteranceHandler(_ handler: @escaping @Sendable (String) -> Void) async
}

extension StreamingEouAsrManager: FluidAudioStreamingTranscribing {
  func resetSession() async {
    await reset()
  }

  func streamAudio(_ buffer: AVAudioPCMBuffer) async throws {
    _ = try await process(audioBuffer: buffer)
  }

  func finishSession() async throws -> String {
    try await finish()
  }

  func setPartialTranscriptHandler(_ handler: @escaping @Sendable (String) -> Void) async {
    await setPartialTranscriptCallback(handler)
  }

  func setUtteranceHandler(_ handler: @escaping @Sendable (String) -> Void) async {
    await setEouCallback(handler)
  }
}

/// Owns the microphone capture side of a FluidAudio run so tests can replace
/// the real `AVAudioEngine` with a deterministic fake.
@MainActor
protocol FluidAudioAudioCapturing: AnyObject {
  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
  func stop()
}

@MainActor
final class FluidAudioEngineCapture: FluidAudioAudioCapturing {
  private var audioEngine: AVAudioEngine?

  func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
    let audioEngine = AVAudioEngine()
    self.audioEngine = audioEngine
    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      throw TranscriptionManagerError.noUsableAudioInput
    }
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
      onBuffer(buffer)
    }
    try await startAudioEngineAfterInputDeviceSettles(audioEngine)
  }

  func stop() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil
  }
}
