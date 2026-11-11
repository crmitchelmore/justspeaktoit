import AVFoundation
import Foundation
import SpeakCore
import os.log

/// The recorder staged ahead of the hotkey (issue #663), its staging folders,
/// and the state machine that decides when to stage, keep or drop it. A value
/// owned by `AudioFileManager`'s actor, so every change stays actor-isolated.
struct CaptureWarmStage {
  /// A recorder created and prepared ahead of the hotkey, waiting to be claimed.
  struct StagedRecorder {
    let context: CaptureWarmContext
    let recorder: AVAudioRecorder
    let id: UUID
    /// Where staging created the file. Outside the recordings directory, so an
    /// unclaimed recorder never leaves an empty recording behind.
    let url: URL
    /// Where the file moves when a session claims the recorder.
    let destination: URL

    /// The claimed recorder, ready to start in its final file.
    var prepared: AudioRecorderFactory.PreparedRecorder {
      AudioRecorderFactory.PreparedRecorder(id: id, url: destination, recorder: recorder, isWarm: true)
    }
  }

  private(set) var staged: StagedRecorder?
  private var stagingDirectories: [String: URL] = [:]
  private var machine = CaptureWarmStateMachine()
  private let logger = Logger(subsystem: "com.github.speakapp", category: "AudioFileManager")

  /// Reconciles the staged recorder with `context`. `captureIdle` is false
  /// while a recording runs or starts, which only ever discards the stage.
  mutating func reconcile(with context: CaptureWarmContext, enabled: Bool, captureIdle: Bool) {
    guard captureIdle else {
      apply(machine.recordingBeganWithoutClaim(), captureIdle: false)
      return
    }
    apply(machine.reconcile(with: context, enabled: enabled), captureIdle: true)
  }

  mutating func reset() {
    apply(machine.reset(), captureIdle: false)
  }

  /// A recording started without the staged recorder, which is now stale.
  mutating func recordingBeganWithoutClaim() {
    apply(machine.recordingBeganWithoutClaim(), captureIdle: false)
  }

  private mutating func apply(_ action: CaptureWarmAction, captureIdle: Bool) {
    switch action {
    case .none:
      return
    case .discard:
      self.discard()
    case .prepare(let context):
      self.prepare(for: context, captureIdle: captureIdle)
    case .discardThenPrepare(let context):
      self.discard()
      self.prepare(for: context, captureIdle: captureIdle)
    }
  }

  /// Creates and prepares a recorder ahead of the hotkey so session start only
  /// has to call `record()`.
  ///
  /// **Privacy boundary.** `AVAudioRecorder.prepareToRecord()` creates the
  /// output file and readies the encoder; it is `record()` that starts pulling
  /// samples from the microphone and lights the macOS recording indicator.
  /// Nothing in this method starts capture, and nothing here may ever call
  /// `record()` — the staged recorder stays silent until a real session claims
  /// it. Staging is also skipped entirely unless microphone permission has
  /// already been granted (see ``CaptureWarmContext/isWarmable``), so warm-up
  /// can never be the thing that provokes a permission prompt.
  ///
  private mutating func prepare(for context: CaptureWarmContext, captureIdle: Bool) {
    guard captureIdle, context.isWarmable else {
      self.machine.markFailed(context)
      return
    }
    if let staged = self.staged {
      guard staged.context != context else {
        _ = self.machine.markReady(context)
        return
      }
      self.discard()
    }

    let id = UUID()
    let directory = URL(fileURLWithPath: context.recordingsDirectoryPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "Recording-\(id.uuidString).m4a"
    let destination = directory.appendingPathComponent(name)
    let staging = self.stagingDirectory(for: directory)
    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let fileURL = staging.appendingPathComponent(name)

    do {
      let warmRecorder = try AVAudioRecorder(url: fileURL, settings: AudioRecorderFactory.encoderSettings)
      warmRecorder.isMeteringEnabled = true
      // Creates the file and readies the encoder. Does NOT open the microphone.
      guard warmRecorder.prepareToRecord() else {
        _ = warmRecorder.deleteRecording()
        try? FileManager.default.removeItem(at: fileURL)
        self.machine.markFailed(context)
        return
      }
      self.staged = StagedRecorder(
        context: context,
        recorder: warmRecorder,
        id: id,
        url: fileURL,
        destination: destination
      )
      if !self.machine.markReady(context) {
        self.discard()
      }
    } catch {
      self.logger.debug("Capture pre-warm failed; falling back to cold start")
      try? FileManager.default.removeItem(at: fileURL)
      self.machine.markFailed(context)
    }
  }

  /// The folder staged files belong in for `recordingsDirectory`. Resolving it
  /// reads volume identifiers, so the answer is cached per directory and never
  /// repeated on the capture path.
  private mutating func stagingDirectory(for recordingsDirectory: URL) -> URL {
    if let cached = self.stagingDirectories[recordingsDirectory.path] { return cached }
    let directory = RecordingFiles.resolveStagingDirectory(for: recordingsDirectory)
    self.stagingDirectories[recordingsDirectory.path] = directory
    return directory
  }

  /// Tears the staged recorder down and removes the empty file it created.
  private mutating func discard() {
    guard let staged = self.staged else { return }
    self.staged = nil
    _ = staged.recorder.deleteRecording()
    do {
      try FileManager.default.removeItem(at: staged.url)
    } catch where (error as NSError).code == NSFileNoSuchFileError {
      return
    } catch {
      self.logger.error("Failed to remove staged recording: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Hands the staged recorder to a starting session, moving its file into the
  /// recordings directory first.
  ///
  /// The move happens before `record()`, and the recorder keeps writing through
  /// the file it opened during staging, so the session records straight into
  /// its final home. Staging and destination always share a volume, which keeps
  /// this a rename. A move that fails leaves the session on the cold path
  /// rather than recording somewhere the user cannot reach.
  mutating func claim(matching context: CaptureWarmContext?) -> StagedRecorder? {
    guard let context, self.machine.claim(for: context) else { return nil }
    guard let staged = self.staged, staged.context == context else { return nil }
    self.staged = nil
    do {
      try FileManager.default.moveItem(at: staged.url, to: staged.destination)
    } catch {
      self.logger.error(
        "Failed to claim staged recording: \(error.localizedDescription, privacy: .public)")
      _ = staged.recorder.deleteRecording()
      try? FileManager.default.removeItem(at: staged.url)
      return nil
    }
    return staged
  }
}
