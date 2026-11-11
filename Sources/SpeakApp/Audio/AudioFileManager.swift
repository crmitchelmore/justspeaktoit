import AVFoundation
import Foundation
import SpeakCore
import os.log

/// Records the microphone into the recordings directory: starts (claiming the
/// recorder `CaptureWarmStage` staged when it can), stops and cancels
/// recordings, and serves the recordings list. One recording at a time, and
/// each flow may only stop or cancel the recording it owns (issue #673).
actor AudioFileManager {
  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let captureSource: (any RecordingCaptureSource)?
  private var captureSourceGeneration: UUID?
  private var sourceTeardownCount = 0
  nonisolated var requiresPhysicalInput: Bool { captureSource == nil }
  private var recorder: AVAudioRecorder? {
    didSet { meter.attach(recorder) }
  }
  /// Reads the running recorder's level without entering the actor.
  private nonisolated let meter = RecorderMeter()
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
  private var warmStage = CaptureWarmStage()
  private var lifecycleHandler: (@Sendable (AudioRecordingLifecycleEvent) -> Void)?
  private let logger = Logger(subsystem: "com.github.speakapp", category: "AudioFileManager")

  /// Identifier for the encoder settings every recording uses.
  static let encoderProfileID = AudioRecorderFactory.encoderProfileID
  /// How long a microphone permission answer stays authoritative for a
  /// capture start. Covers a hold or double tap after key-down with margin.
  static let microphoneStatusMaxAge: TimeInterval = 2

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    captureSource: (any RecordingCaptureSource)? = nil
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.captureSource = captureSource
  }

  /// One meter update: the normalized level (0.0 to 1.0) and the peak input
  /// power in dBFS. Nil when no recorder is running.
  nonisolated func getCurrentMeterReading() -> (level: Float, peakDecibels: Float)? {
    meter.reading()
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
    guard captureSource == nil else { return }
    warmStage.reconcile(with: context, enabled: enabled, captureIdle: isIdle)
  }

  func invalidateWarmRecorder() {
    warmStage.reset()
  }

  /// No recording is running, starting or being torn down.
  private var isIdle: Bool {
    recorder == nil && currentRecordingURL == nil && !isStartingRecording && sourceTeardownCount == 0
  }

  // MARK: - Recording

  /// Reads the main-actor state a capture start needs, synchronously on the
  /// main actor, so `startRecording(preflight:)` can open the microphone
  /// without waiting for the main thread. Begins the preferred-input session
  /// only when the microphone is already granted; otherwise the start falls
  /// back to the authoritative request path.
  @MainActor
  func makeStartPreflight() async -> CaptureStartPreflight {
    permissionsManager.refresh(.microphone, ifOlderThan: Self.microphoneStatusMaxAge)
    let granted = permissionsManager.status(for: .microphone).isGranted
    let inputSession = granted ? await audioDeviceManager.beginUsingPreferredInput() : nil
    return CaptureStartPreflight(
      microphoneGranted: granted,
      recordingsDirectory: appSettings.recordingsDirectory,
      inputSession: inputSession
    )
  }

  /// Starts capture, claiming the staged recorder when `warmContext` matches
  /// the one it was prepared for. On the warm path the only work left on the
  /// hotkey→capture path is the input-device session and `record()` itself.
  /// Three steps: authorise the microphone, prepare a recorder (warm or cold),
  /// then open the input and arm the recording.
  ///
  /// - Parameter preflight: main-actor state read by `makeStartPreflight()`.
  ///   With a granted preflight nothing here waits for the main actor before
  ///   `record()`. This call owns its input session, including when it throws.
  func startRecording(
    warmContext: CaptureWarmContext? = nil,
    owner: AudioRecordingOwner = .auxiliary,
    preflight: CaptureStartPreflight? = nil
  ) async throws -> RecordingStart {
    guard isIdle else {
      await endPreflightInput(preflight)
      throw AudioFileManagerError.alreadyRecording
    }
    self.isStartingRecording = true
    defer { self.isStartingRecording = false }

    if let captureSource {
      await endPreflightInput(preflight)
      return try await startCaptureSource(captureSource, owner: owner)
    }

    let permissionGranted = try await authoriseMicrophone(preflight)
    let claimed = warmStage.claim(matching: warmContext)
    // A staged recorder the starting session cannot use is stale by definition:
    // discard it rather than leave an orphaned file behind.
    if claimed == nil {
      warmStage.recordingBeganWithoutClaim()
    }

    let sessionContext: AudioInputDeviceManager.SessionContext
    if permissionGranted, let preflightSession = preflight?.inputSession {
      sessionContext = preflightSession
    } else {
      sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    }
    do {
      let captureRequestedAt = Date()
      let (prepared, directory) = try await prepareRecorder(claimed, directory: preflight?.recordingsDirectory)
      let recordRequestedUptime = ProcessInfo.processInfo.systemUptime
      let started = try AudioRecorderFactory.startCapture(with: prepared, in: directory, logger: logger)
      let liveUptime = ProcessInfo.processInfo.systemUptime
      var start = arm(started, owner: owner, inputSession: sessionContext, requestedAt: captureRequestedAt)
      start.liveUptime = liveUptime
      start.recorderOpenMilliseconds = Int(((liveUptime - recordRequestedUptime) * 1000).rounded())
      return start
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

  /// Throws unless the microphone may be used, asking only when the status is
  /// not already granted. Returns whether it was granted without asking, the
  /// only case in which a preflight input session is used.
  private func authoriseMicrophone(_ preflight: CaptureStartPreflight?) async throws -> Bool {
    let permissionGranted: Bool
    if let preflight {
      permissionGranted = preflight.microphoneGranted
    } else {
      permissionGranted = await MainActor.run {
        // Reuses the authoritative query made at hotkey key-down when it is
        // fresh, keeping 15-35 ms of TCC off the trigger-to-capture path (#611).
        permissionsManager.refresh(.microphone, ifOlderThan: Self.microphoneStatusMaxAge)
        return permissionsManager.status(for: .microphone).isGranted
      }
    }
    guard !permissionGranted else { return true }
    await endPreflightInput(preflight)
    self.invalidateWarmRecorder()
    let requested = await permissionsManager.request(.microphone)
    guard requested.isGranted else {
      throw AudioFileManagerError.microphonePermissionMissing
    }
    return false
  }

  /// The claimed staged recorder, or a cold one built in the recordings directory.
  private func prepareRecorder(
    _ claimed: CaptureWarmStage.StagedRecorder?,
    directory preflightDirectory: URL?
  ) async throws -> (AudioRecorderFactory.PreparedRecorder, URL) {
    if let claimed {
      return (claimed.prepared, claimed.destination.deletingLastPathComponent())
    }
    let directory: URL
    if let preflightDirectory {
      directory = preflightDirectory
    } else {
      directory = await MainActor.run { appSettings.recordingsDirectory }
    }
    return (try AudioRecorderFactory.makeRecorder(in: directory), directory)
  }

  /// Ends the input session a preflight began for a start that will not use it.
  private func endPreflightInput(_ preflight: CaptureStartPreflight?) async {
    guard let session = preflight?.inputSession else { return }
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  /// Publishes a recorder that proved it captures as the active recording.
  private func arm(
    _ started: AudioRecorderFactory.PreparedRecorder,
    owner: AudioRecordingOwner,
    inputSession: AudioInputDeviceManager.SessionContext,
    requestedAt captureRequestedAt: Date
  ) -> RecordingStart {
    let startDate = Date()
    let readyDelay = startDate.timeIntervalSince(captureRequestedAt)
    logger.info("Audio capture confirmed live \(Int(readyDelay * 1000))ms after start request")
    recorder = started.recorder
    currentRecordingID = started.id
    currentRecordingURL = started.url
    currentRecordingStart = startDate
    currentRecordingOwner = owner
    activeInputSession = inputSession
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
  }

  /// Reserve ownership before either await: cancellation can arrive while the
  /// directory is resolved or while an alternate source is still starting.
  private func startCaptureSource(
    _ source: any RecordingCaptureSource, owner: AudioRecordingOwner
  ) async throws -> RecordingStart {
    let generation = UUID()
    captureSourceGeneration = generation
    currentRecordingOwner = owner
    do {
      let directory = await MainActor.run { appSettings.recordingsDirectory }
      guard captureSourceGeneration == generation, !Task.isCancelled else { throw CancellationError() }
      let started = try await source.start(in: directory)
      guard captureSourceGeneration == generation, !Task.isCancelled else {
        // isStartingRecording still reserves admission until this cleanup ends,
        // so source.cancel cannot tear down a replacement capture.
        await source.cancel(deleteFile: true)
        try? FileManager.default.removeItem(at: started.url)
        throw CancellationError()
      }
      currentRecordingURL = started.url
      if owner != .dictation { lifecycleHandler?(.auxiliaryStarted) }
      return started
    } catch {
      if captureSourceGeneration == generation {
        captureSourceGeneration = nil
        currentRecordingOwner = nil
      }
      throw error
    }
  }

  func stopRecording() async throws -> RecordingSummary {
    if let captureSource {
      guard currentRecordingURL != nil, let generation = captureSourceGeneration,
            sourceTeardownCount == 0 else { throw AudioFileManagerError.noActiveRecording }
      let owner = currentRecordingOwner
      sourceTeardownCount += 1
      defer { sourceTeardownCount -= 1 }
      let summary = try await captureSource.stop()
      guard captureSourceGeneration == generation, !Task.isCancelled else { throw CancellationError() }
      captureSourceGeneration = nil
      currentRecordingURL = nil
      currentRecordingOwner = nil
      if let owner, owner != .dictation { lifecycleHandler?(.auxiliaryEnded) }
      return summary
    }
    guard let recorder, let recordingID = currentRecordingID, let start = currentRecordingStart else {
      throw AudioFileManagerError.noActiveRecording
    }

    let owner = self.currentRecordingOwner
    let url = self.currentRecordingURL ?? recorder.url
    recorder.stop()
    clearCurrentRecording()
    let measuredDuration = recorder.currentTime
    let summary = AudioRecorderFactory.summary(
      of: url, id: recordingID, startedAt: start, measuredDuration: measuredDuration
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

  private func clearCurrentRecording() {
    recorder = nil
    currentRecordingStart = nil
    currentRecordingID = nil
    currentRecordingOwner = nil
    currentRecordingURL = nil
  }

  /// Cancels the active recording. When `expectedOwner` is given, a recording
  /// owned by another flow is left untouched: each flow may only cancel what
  /// it started (issue #673). Returns the kept file when `deleteFile` is false
  /// and a non-empty recording existed.
  @discardableResult
  func cancelRecording(
    deleteFile: Bool = true,
    ifOwnedBy expectedOwner: AudioRecordingOwner? = nil
  ) async -> URL? {
    if let expectedOwner, let currentOwner = currentRecordingOwner, currentOwner != expectedOwner {
      return nil
    }
    if let captureSource {
      let owner = currentRecordingOwner
      let url = currentRecordingURL
      // Invalidate and clear synchronously. A suspended start/stop cannot
      // republish this recording when the source resumes after cancellation.
      captureSourceGeneration = nil
      currentRecordingURL = nil
      currentRecordingOwner = nil
      sourceTeardownCount += 1
      defer { sourceTeardownCount -= 1 }
      await captureSource.cancel(deleteFile: deleteFile)
      if deleteFile, let url { try? FileManager.default.removeItem(at: url) }
      if url != nil, let owner, owner != .dictation { lifecycleHandler?(.auxiliaryEnded) }
      return deleteFile ? nil : RecordingFiles.keptRecording(at: url)
    }
    let session = activeInputSession
    let owner = currentRecordingOwner
    var keptURL: URL?

    if let recorder {
      let url = self.currentRecordingURL ?? recorder.url
      recorder.stop()
      clearCurrentRecording()
      if deleteFile {
        try? FileManager.default.removeItem(at: url)
      } else {
        keptURL = RecordingFiles.keptRecording(at: url)
      }
    }

    if let session {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
    }

    if let owner, owner != .dictation {
      self.lifecycleHandler?(.auxiliaryEnded)
    }
    return keptURL
  }

  /// Metadata-only listing for recording management. Listed durations are zero;
  /// neither cleanup caller needs to open or decode the user's audio files.
  func listRecordings() async -> [RecordingSummary] {
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    // A start reserves ownership across awaits before currentRecordingURL is set
    // (including claiming a warm file). Never snapshot that unfinished capture.
    guard !isStartingRecording else { return [] }
    // Keep the metadata walk on this actor: without a suspension, a new capture
    // cannot enter the deletion snapshot halfway through enumeration. This also
    // avoids accumulating detached walks against a slow or unavailable volume.
    return RecordingFiles.listRecordings(in: directory, excluding: currentRecordingURL)
  }

  func removeRecording(at url: URL) {
    // Capture can start between snapshot creation and this call. Reserve the
    // entire startup interval, including a claimed warm file awaiting device setup.
    guard !isStartingRecording else { return }
    RecordingFiles.removeRecording(at: url, excluding: currentRecordingURL)
  }

  func importRecording(from url: URL) async throws -> URL {
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    return try RecordingFiles.importRecording(from: url, into: directory)
  }
}
