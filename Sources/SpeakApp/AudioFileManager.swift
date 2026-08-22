import AVFoundation
import Foundation
import SpeakCore
import os.log

// @Implement: This file manages the audio recording bit rate and other audio settings. It also depends on app settings to know where to write the audio files to. It never loses any data during recording. It also has the ability to manager audio files e.g. listing, deleting, accessing etc.

struct RecordingSummary: Identifiable, Hashable {
  let id: UUID
  let url: URL
  let startedAt: Date
  let duration: TimeInterval
  let fileSize: Int64
}

enum AudioRecordingOwner: Sendable {
  case dictation
  case auxiliary
  /// A Voice Edit instruction recording. Reported to the warm coordinator like
  /// any auxiliary capture, but identified so dictation's failure cleanup can
  /// never cancel it (issue #673).
  case voiceEdit
}

enum AudioRecordingLifecycleEvent: Sendable {
  case auxiliaryStarted
  case auxiliaryEnded
}

struct RecordingStart: Sendable {
  let url: URL
  let usedWarmRecorder: Bool
}

enum AudioFileManagerError: LocalizedError {
  case alreadyRecording
  case noActiveRecording
  case microphonePermissionMissing
  case failedToConfigureSession
  case failedToCreateRecorder
  case failedToStartCapture

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "A recording session is already active."
    case .noActiveRecording:
      return "No active recording session is running."
    case .microphonePermissionMissing:
      return "Microphone permission has not been granted."
    case .failedToConfigureSession:
      return "Failed to configure the audio session."
    case .failedToCreateRecorder:
      return "Could not create the audio recorder."
    case .failedToStartCapture:
      return "The microphone did not start capturing. Check the input device and try again."
    }
  }
}

actor AudioFileManager { // swiftlint:disable:this type_body_length
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

  /// A recorder created and prepared ahead of the hotkey, waiting to be claimed.
  private struct StagedRecorder {
    let context: CaptureWarmContext
    let recorder: AVAudioRecorder
    let id: UUID
    /// Where staging created the file. Outside the recordings directory, so an
    /// unclaimed recorder never leaves an empty recording behind.
    let url: URL
    /// Where the file moves when a session claims the recorder.
    let destination: URL
  }

  /// A recorder that is ready to start, and the file its audio lands in.
  private struct PreparedRecorder {
    let id: UUID
    let url: URL
    let recorder: AVAudioRecorder
    /// Whether the recorder was staged ahead of the hotkey.
    let isWarm: Bool
  }

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  // nonisolated(unsafe) allows thread-safe metering access from timer callbacks
  // AVAudioRecorder metering methods are documented as thread-safe
  nonisolated(unsafe) private var recorder: AVAudioRecorder?
  private var currentRecordingID: UUID?
  private var currentRecordingStart: Date?
  private var currentRecordingOwner: AudioRecordingOwner?
  /// Where the active recording lands. A claimed warm recorder still reports
  /// the staging path in `AVAudioRecorder.url`, so the actor tracks the real
  /// destination itself.
  private var currentRecordingURL: URL?
  /// Reserves the recorder across permission and input-device awaits. Without
  /// this, actor reentrancy can admit a second start or stage a new warm
  /// recorder while the first start is still configuring its input session.
  private var isStartingRecording = false
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var staged: StagedRecorder?
  private var stagingDirectories: [String: URL] = [:]
  private var warmMachine = CaptureWarmStateMachine()
  private var lifecycleHandler: (@Sendable (AudioRecordingLifecycleEvent) -> Void)?
  private let logger = Logger(subsystem: "com.github.speakapp", category: "AudioFileManager")

  /// Identifier for the encoder settings every recording uses.
  static let encoderProfileID = EncoderProfile.id

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
  }

  /// Returns the current audio level (0.0 to 1.0) if recording is active.
  /// Call this periodically (~30fps) to get updated levels.
  /// Note: nonisolated because it only reads from AVAudioRecorder which is thread-safe for metering
  nonisolated func getCurrentAudioLevel() -> Float {
    // AVAudioRecorder metering methods are documented as thread-safe
    // We access recorder directly without actor isolation for 30fps polling performance
    guard let recorder = self.recorder, recorder.isRecording else { return 0 }
    recorder.updateMeters()

    let averagePower = recorder.averagePower(forChannel: 0)
    let peakPower = recorder.peakPower(forChannel: 0)

    // Combine average and peak for responsive meter
    let combinedPower = (averagePower * 0.7) + (peakPower * 0.3)

    // Convert decibels to normalized linear scale (0.0 to 1.0)
    // -60 dB = silence threshold, 0 dB = maximum
    let minDb: Float = -60
    return max(0, min(1, (combinedPower - minDb) / (-minDb)))
  }

  // MARK: - Pre-warming (issue #663)

  func setRecordingLifecycleHandler(
    _ handler: (@Sendable (AudioRecordingLifecycleEvent) -> Void)?
  ) {
    self.lifecycleHandler = handler
  }

  /// Reconciles the staged recorder and its state as one actor-owned operation.
  /// Keeping both together prevents auxiliary recording flows from invalidating
  /// the recorder while a separate coordinator still believes it is ready.
  func reconcileWarmRecorder(for context: CaptureWarmContext, enabled: Bool) {
    guard self.recorder == nil, !self.isStartingRecording else {
      self.applyWarmAction(self.warmMachine.recordingBeganWithoutClaim())
      return
    }
    self.applyWarmAction(self.warmMachine.reconcile(with: context, enabled: enabled))
  }

  func invalidateWarmRecorder() {
    self.applyWarmAction(self.warmMachine.reset())
  }

  private func applyWarmAction(_ action: CaptureWarmAction) {
    switch action {
    case .none:
      return
    case .discard:
      self.discardWarmRecorder()
    case .prepare(let context):
      self.prepareWarmRecorder(for: context)
    case .discardThenPrepare(let context):
      self.discardWarmRecorder()
      self.prepareWarmRecorder(for: context)
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
  private func prepareWarmRecorder(for context: CaptureWarmContext) {
    guard self.recorder == nil, context.isWarmable else {
      self.warmMachine.markFailed(context)
      return
    }
    if let staged = self.staged {
      guard staged.context != context else {
        _ = self.warmMachine.markReady(context)
        return
      }
      self.discardWarmRecorder()
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
      let warmRecorder = try AVAudioRecorder(url: fileURL, settings: EncoderProfile.settings)
      warmRecorder.isMeteringEnabled = true
      // Creates the file and readies the encoder. Does NOT open the microphone.
      guard warmRecorder.prepareToRecord() else {
        _ = warmRecorder.deleteRecording()
        try? FileManager.default.removeItem(at: fileURL)
        self.warmMachine.markFailed(context)
        return
      }
      self.staged = StagedRecorder(
        context: context,
        recorder: warmRecorder,
        id: id,
        url: fileURL,
        destination: destination
      )
      if !self.warmMachine.markReady(context) {
        self.discardWarmRecorder()
      }
    } catch {
      self.logger.debug("Capture pre-warm failed; falling back to cold start")
      try? FileManager.default.removeItem(at: fileURL)
      self.warmMachine.markFailed(context)
    }
  }

  /// The folder staged files belong in for `recordingsDirectory`. Resolving it
  /// reads volume identifiers, so the answer is cached per directory and never
  /// repeated on the capture path.
  private func stagingDirectory(for recordingsDirectory: URL) -> URL {
    if let cached = self.stagingDirectories[recordingsDirectory.path] { return cached }
    let directory = Self.resolveStagingDirectory(for: recordingsDirectory)
    self.stagingDirectories[recordingsDirectory.path] = directory
    return directory
  }

  /// See ``CaptureStaging`` for why the choice depends on which volume the
  /// recordings directory is on.
  private static func resolveStagingDirectory(for recordingsDirectory: URL) -> URL {
    let temporary = FileManager.default.temporaryDirectory
    return CaptureStaging.directory(
      temporaryDirectory: temporary,
      recordingsDirectory: recordingsDirectory,
      sharesVolume: self.sharesVolume(temporary, recordingsDirectory)
    )
  }

  /// Whether both URLs sit on the same volume, which is what makes claiming a
  /// staged recorder a rename rather than a copy. Unknown answers count as
  /// "no", so an unreadable volume identifier keeps staging beside the
  /// recordings directory instead of risking a cross-volume move.
  private static func sharesVolume(_ lhs: URL, _ rhs: URL) -> Bool {
    guard
      let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
      let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    else {
      return false
    }
    return left.isEqual(right)
  }

  /// Asks for the staging folder of `recordingsDirectory` to be swept.
  ///
  /// The owner calls this from the composition root at launch, and again
  /// whenever the recordings directory changes, for the old folder and the new
  /// one. Creating a recorder deliberately starts nothing: a test or a preview
  /// that builds one must never reach a real recordings directory, so the
  /// trigger belongs to whoever knows the app is really running.
  ///
  /// Housekeeping must also never stand in front of a session. On the actor,
  /// the directory scan would hold every other message — the warm-up handshake
  /// and `startRecording` included — behind it for as long as it ran, which is
  /// exactly the delay pre-warming exists to remove. The sweep therefore runs
  /// detached, at utility priority, and only once the launch has settled.
  static func scheduleStagedLeftoverSweep(in recordingsDirectory: URL) {
    Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
      Self.sweepStagedLeftovers(in: recordingsDirectory, now: Date())
    }
  }

  /// Removes staged files no session ever claimed.
  ///
  /// A crash, a force quit or a power loss between staging a recorder and the
  /// hotkey leaves its file behind, and nothing runs on the way out to clean
  /// it up. This sweep runs once per launch and only takes files that have
  /// been untouched for ``CaptureStaging/leftoverAge``, so it can never reach
  /// a file the running app still owns.
  private static func sweepStagedLeftovers(in recordingsDirectory: URL, now: Date) {
    let manager = FileManager.default

    let staging = self.resolveStagingDirectory(for: recordingsDirectory)
    let stagedKeys: [URLResourceKey] = [.contentModificationDateKey]
    let stagedFiles =
      (try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: stagedKeys)) ?? []
    for url in stagedFiles {
      let modified = (try? url.resourceValues(forKeys: Set(stagedKeys)))?.contentModificationDate
      guard CaptureStaging.isLeftover(modifiedAt: modified ?? .distantFuture, now: now) else {
        continue
      }
      try? manager.removeItem(at: url)
    }

    // Builds before staging moved out of the recordings directory left their
    // unclaimed files there. Clear those too, on the same age rule.
    let inPlaceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let recordings =
      (try? manager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: inPlaceKeys))
      ?? []
    for url in recordings {
      let values = try? url.resourceValues(forKeys: Set(inPlaceKeys))
      guard
        CaptureStaging.isAbandonedInPlaceStage(
          fileName: url.lastPathComponent,
          byteSize: values?.fileSize ?? .max,
          modifiedAt: values?.contentModificationDate ?? .distantFuture,
          now: now
        )
      else {
        continue
      }
      try? manager.removeItem(at: url)
    }
  }

  /// Tears the staged recorder down and removes the empty file it created.
  private func discardWarmRecorder() {
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

  // MARK: - Recording

  /// Starts capture, claiming the staged recorder when `warmContext` matches
  /// the one it was prepared for. On the warm path the only work left on the
  /// hotkey→capture path is the input-device session and `record()` itself.
  func startRecording( // swiftlint:disable:this function_body_length
    warmContext: CaptureWarmContext? = nil,
    owner: AudioRecordingOwner = .auxiliary
  ) async throws -> RecordingStart {
    guard self.recorder == nil, !self.isStartingRecording else {
      throw AudioFileManagerError.alreadyRecording
    }
    self.isStartingRecording = true
    defer { self.isStartingRecording = false }

    let permissionStatus = await MainActor.run {
      permissionsManager.refresh(.microphone)
      return permissionsManager.status(for: .microphone)
    }
    if !permissionStatus.isGranted {
      self.invalidateWarmRecorder()
      let requested = await permissionsManager.request(.microphone)
      guard requested.isGranted else {
        throw AudioFileManagerError.microphonePermissionMissing
      }
    }

    let claimed = self.claimWarmRecorder(matching: warmContext)
    // A staged recorder the starting session cannot use is stale by definition:
    // discard it rather than leave an orphaned file behind.
    if claimed == nil {
      self.applyWarmAction(self.warmMachine.recordingBeganWithoutClaim())
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()

    do {
      let captureRequestedAt = Date()
      let directory: URL
      let prepared: PreparedRecorder
      if let claimed {
        directory = claimed.destination.deletingLastPathComponent()
        prepared = PreparedRecorder(
          id: claimed.id,
          url: claimed.destination,
          recorder: claimed.recorder,
          isWarm: true
        )
      } else {
        directory = await MainActor.run { appSettings.recordingsDirectory }
        prepared = try self.makeRecorder(in: directory)
      }

      let started = try self.startCapture(with: prepared, in: directory)
      let startDate = Date()
      let readyDelay = startDate.timeIntervalSince(captureRequestedAt)
      logger.info("Audio capture confirmed live \(Int(readyDelay * 1000))ms after start request")
      recorder = started.recorder
      currentRecordingID = started.id
      currentRecordingURL = started.url
      currentRecordingStart = startDate
      currentRecordingOwner = owner
      activeInputSession = sessionContext
      if started.isWarm {
        // The staged file was created while the app was idle, so its creation
        // date would otherwise misdate the recording in listings.
        try? FileManager.default.setAttributes(
          [.creationDate: startDate], ofItemAtPath: started.url.path)
      }
      if owner != .dictation {
        self.lifecycleHandler?(.auxiliaryStarted)
      }
      return RecordingStart(url: started.url, usedWarmRecorder: started.isWarm)
    } catch let error as AudioFileManagerError {
      // Capture that never started (or a recorder we could not build) must
      // surface as itself: the start sequencer distinguishes them, and only a
      // confirmed capture is allowed to play the cue.
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw error
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw AudioFileManagerError.failedToCreateRecorder
    }
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
  private func startCapture(with prepared: PreparedRecorder, in directory: URL) throws -> PreparedRecorder {
    if self.proveCapture(of: prepared.recorder) { return prepared }
    self.discard(prepared)
    guard prepared.isWarm else { throw AudioFileManagerError.failedToStartCapture }
    self.logger.warning("Pre-warmed recorder failed to prove capture; retrying from cold")

    let cold = try self.makeRecorder(in: directory)
    guard self.proveCapture(of: cold.recorder) else {
      self.discard(cold)
      throw AudioFileManagerError.failedToStartCapture
    }
    return cold
  }

  /// True once the recorder both accepted `record()` and reports
  /// `isRecording`. Stops it again on failure so `discard` always tears down a
  /// quiescent recorder.
  private func proveCapture(of recorder: AVAudioRecorder) -> Bool {
    guard recorder.record(), recorder.isRecording else {
      recorder.stop()
      return false
    }
    return true
  }

  /// Creates and prepares a recorder in the recordings directory itself. Used
  /// by the cold path, where the file is written to from the moment it exists.
  private func makeRecorder(in directory: URL) throws -> PreparedRecorder {
    let id = UUID()
    let fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).m4a")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let newRecorder = try AVAudioRecorder(url: fileURL, settings: EncoderProfile.settings)
      newRecorder.isMeteringEnabled = true
      let prepared = PreparedRecorder(id: id, url: fileURL, recorder: newRecorder, isWarm: false)
      guard newRecorder.prepareToRecord() else {
        self.discard(prepared)
        throw AudioFileManagerError.failedToCreateRecorder
      }
      return prepared
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      throw AudioFileManagerError.failedToCreateRecorder
    }
  }

  private func discard(_ prepared: PreparedRecorder) {
    _ = prepared.recorder.deleteRecording()
    try? FileManager.default.removeItem(at: prepared.url)
  }

  /// Hands the staged recorder to a starting session, moving its file into the
  /// recordings directory first.
  ///
  /// The move happens before `record()`, and the recorder keeps writing through
  /// the file it opened during staging, so the session records straight into
  /// its final home. Staging and destination always share a volume, which keeps
  /// this a rename. A move that fails leaves the session on the cold path
  /// rather than recording somewhere the user cannot reach.
  private func claimWarmRecorder(matching context: CaptureWarmContext?) -> StagedRecorder? {
    guard let context, self.warmMachine.claim(for: context) else { return nil }
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

  func stopRecording() async throws -> RecordingSummary {
    guard let recorder, let recordingID = currentRecordingID, let start = currentRecordingStart else {
      throw AudioFileManagerError.noActiveRecording
    }

    let owner = self.currentRecordingOwner
    let url = self.currentRecordingURL ?? recorder.url
    recorder.stop()
    self.recorder = nil
    self.currentRecordingStart = nil
    self.currentRecordingID = nil
    self.currentRecordingOwner = nil
    self.currentRecordingURL = nil
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let measuredDuration = recorder.currentTime
    let preciseDuration = (try? AVAudioPlayer(contentsOf: url).duration) ?? measuredDuration
    let duration =
      preciseDuration.isFinite && preciseDuration > 0 ? preciseDuration : measuredDuration

    let summary = RecordingSummary(
      id: recordingID,
      url: url,
      startedAt: start,
      duration: duration,
      fileSize: fileSize
    )

    if let session = activeInputSession {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
    }

    if owner != .dictation {
      self.lifecycleHandler?(.auxiliaryEnded)
    }

    return summary
  }

  /// Cancels the active recording. When `expectedOwner` is given, a recording
  /// owned by another flow is left untouched: each flow may only cancel what
  /// it started (issue #673).
  func cancelRecording(
    deleteFile: Bool = true,
    ifOwnedBy expectedOwner: AudioRecordingOwner? = nil
  ) async {
    if let expectedOwner, let currentOwner = currentRecordingOwner, currentOwner != expectedOwner {
      return
    }
    let session = activeInputSession
    let owner = currentRecordingOwner

    if let recorder {
      let url = self.currentRecordingURL ?? recorder.url
      recorder.stop()
      self.recorder = nil
      currentRecordingStart = nil
      currentRecordingID = nil
      currentRecordingOwner = nil
      currentRecordingURL = nil
      if deleteFile {
        try? FileManager.default.removeItem(at: url)
      }
    }

    if let session {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
    }

    if let owner, owner != .dictation {
      self.lifecycleHandler?(.auxiliaryEnded)
    }
  }

  func listRecordings() async -> [RecordingSummary] {
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
        // Keeps the hidden staging folder, which holds files no session has
        // claimed, out of the user's recordings list.
        options: [.skipsHiddenFiles])
    else {
      return []
    }

    let allowedExtensions: Set<String> = ["m4a", "wav", "mp3", "aac", "m4b", "caf"]

    var summaries: [RecordingSummary] = []
    while let next = enumerator.nextObject() as? URL {
      let url = next
      guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
      do {
        let resource = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let creationDate = resource.creationDate ?? Date()
        let fileSize = Int64(resource.fileSize ?? 0)
        let stem = url.deletingPathExtension().lastPathComponent
          .replacingOccurrences(of: "Recording-", with: "")
          .replacingOccurrences(of: "Imported-", with: "")
        let id = UUID(uuidString: stem) ?? UUID()
        let duration = try AVAudioPlayer(contentsOf: url).duration
        summaries.append(
          RecordingSummary(
            id: id,
            url: url,
            startedAt: creationDate,
            duration: duration,
            fileSize: fileSize
          )
        )
      } catch {
        continue
      }
    }
    return summaries.sorted { $0.startedAt > $1.startedAt }
  }

  func removeRecording(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  func importRecording(from url: URL) async throws -> URL {
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
    let id = UUID()
    let destination = directory.appendingPathComponent("Imported-\(id.uuidString).\(ext)")
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }
} // swiftlint:disable:this file_length
