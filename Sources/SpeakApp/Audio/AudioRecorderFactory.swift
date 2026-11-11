import AVFoundation
import Foundation
import os.log

/// Builds, starts and tears down the `AVAudioRecorder` behind a recording,
/// with one encoder profile for every recording.
enum AudioRecorderFactory {
  /// AAC encoder settings for every recording. Kept as one value so the warm-up
  /// fingerprint can name the exact profile a staged recorder was built for.
  private enum EncoderProfile {
    static let id = "aac-44100-mono-128k"
    static var settings: [String: Any] {
      [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
      ]
    }
  }

  /// Identifier for the encoder settings every recording uses.
  static let encoderProfileID = EncoderProfile.id
  static var encoderSettings: [String: Any] { EncoderProfile.settings }

  /// A recorder that is ready to start, and the file its audio lands in.
  struct PreparedRecorder {
    let id: UUID
    let url: URL
    let recorder: AVAudioRecorder
    /// Whether the recorder was staged ahead of the hotkey.
    let isWarm: Bool
  }

  /// Opens the microphone and only returns once the recorder proves it is
  /// capturing, falling back to a cold recorder once when a staged one refuses
  /// to start. A staged recorder that fails is worth a few milliseconds of
  /// extra latency, never the dictation itself.
  ///
  /// Issue #641: the caller plays the start cue on the strength of this
  /// returning, so readiness has to be proven rather than assumed. `record()`
  /// answering false (or a recorder that never flips to `isRecording`) used to
  /// be swallowed, leaving the user speaking into a microphone that was not
  /// running. Warm and cold recorders are held to the same proof — a staged
  /// recorder can be just as dead. On failure, `discard` removes
  /// `prepared.url`: for a claimed warm recorder that is the destination its
  /// staging file was renamed to, not the stale staging path
  /// `AVAudioRecorder.url` still reports after the move.
  static func startCapture(
    with prepared: PreparedRecorder,
    in directory: URL,
    logger: Logger
  ) throws -> PreparedRecorder {
    if Self.proveCapture(of: prepared.recorder) { return prepared }
    Self.discard(prepared)
    guard prepared.isWarm else { throw AudioFileManagerError.failedToStartCapture }
    logger.warning("Pre-warmed recorder failed to prove capture; retrying from cold")

    let cold = try Self.makeRecorder(in: directory)
    guard Self.proveCapture(of: cold.recorder) else {
      Self.discard(cold)
      throw AudioFileManagerError.failedToStartCapture
    }
    return cold
  }

  /// True once the recorder both accepted `record()` and reports
  /// `isRecording`. Stops it again on failure so `discard` always tears down a
  /// quiescent recorder.
  private static func proveCapture(of recorder: AVAudioRecorder) -> Bool {
    guard recorder.record(), recorder.isRecording else {
      recorder.stop()
      return false
    }
    return true
  }

  /// Creates and prepares a recorder in the recordings directory itself. Used
  /// by the cold path, where the file is written to from the moment it exists.
  static func makeRecorder(in directory: URL) throws -> PreparedRecorder {
    let id = UUID()
    let fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).m4a")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let newRecorder = try AVAudioRecorder(url: fileURL, settings: EncoderProfile.settings)
      newRecorder.isMeteringEnabled = true
      let prepared = PreparedRecorder(id: id, url: fileURL, recorder: newRecorder, isWarm: false)
      guard newRecorder.prepareToRecord() else {
        Self.discard(prepared)
        throw AudioFileManagerError.failedToCreateRecorder
      }
      return prepared
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      throw AudioFileManagerError.failedToCreateRecorder
    }
  }

  static func discard(_ prepared: PreparedRecorder) {
    _ = prepared.recorder.deleteRecording()
    try? FileManager.default.removeItem(at: prepared.url)
  }

  /// The summary of a finished recording at `url`: its decoded duration when
  /// the file can be read, otherwise what the recorder measured.
  static func summary(of url: URL, id: UUID, startedAt: Date, measuredDuration: TimeInterval) -> RecordingSummary {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let preciseDuration = (try? AVAudioPlayer(contentsOf: url).duration) ?? measuredDuration
    let duration = preciseDuration.isFinite && preciseDuration > 0 ? preciseDuration : measuredDuration
    return RecordingSummary(id: id, url: url, startedAt: startedAt, duration: duration, fileSize: fileSize)
  }
}
