import Foundation
import WhisperKit

/// Keeps WhisperKit's model loading and decoding off the main actor.
///
/// argmax-oss-swift 1.x builds with `NonisolatedNonsendingByDefault`, so its
/// async entry points run on the *caller's* actor. Every app call site is
/// `@MainActor`, which would put multi-second Core ML work on the main thread.
/// These helpers are nonisolated (SpeakApp is in Swift 5 language mode), so an
/// `await` on them leaves the main actor before WhisperKit runs. If SpeakApp
/// ever adopts Swift 6.2 mode, mark them `@concurrent` instead (issue #757).
enum WhisperKitOffMain {
  nonisolated static func load(_ config: WhisperKitConfig) async throws -> WhisperKit {
    try await WhisperKit(config)
  }

  nonisolated static func transcribe(
    _ pipeline: WhisperKit,
    audioArray: [Float],
    decodeOptions: DecodingOptions?
  ) async throws -> [TranscriptionResult] {
    try await pipeline.transcribe(audioArray: audioArray, decodeOptions: decodeOptions)
  }

  nonisolated static func transcribe(
    _ pipeline: WhisperKit,
    audioPath: String,
    decodeOptions: DecodingOptions? = nil
  ) async throws -> [TranscriptionResult] {
    try await pipeline.transcribe(audioPath: audioPath, decodeOptions: decodeOptions)
  }
}
