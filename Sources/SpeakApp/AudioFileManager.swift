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
    let url: URL
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
  /// Reserves the recorder across permission and input-device awaits. Without
  /// this, actor reentrancy can admit a second start or stage a new warm
  /// recorder while the first start is still configuring its input session.
  private var isStartingRecording = false
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var staged: StagedRecorder?
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
    let fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).m4a")

    do {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let warmRecorder = try AVAudioRecorder(url: fileURL, settings: EncoderProfile.settings)
      warmRecorder.isMeteringEnabled = true
      // Creates the file and readies the encoder. Does NOT open the microphone.
      guard warmRecorder.prepareToRecord() else {
        _ = warmRecorder.deleteRecording()
        try? FileManager.default.removeItem(at: fileURL)
        self.warmMachine.markFailed(context)
        return
      }
      self.staged = StagedRecorder(context: context, recorder: warmRecorder, id: id, url: fileURL)
      if !self.warmMachine.markReady(context) {
        self.discardWarmRecorder()
      }
    } catch {
      self.logger.debug("Capture pre-warm failed; falling back to cold start")
      try? FileManager.default.removeItem(at: fileURL)
      self.warmMachine.markFailed(context)
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
      let id: UUID
      let fileURL: URL
      let newRecorder: AVAudioRecorder
      if let claimed {
        id = claimed.id
        fileURL = claimed.url
        newRecorder = claimed.recorder
      } else {
        id = UUID()
        let directory = await MainActor.run { appSettings.recordingsDirectory }
        fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).m4a")
        newRecorder = try AVAudioRecorder(url: fileURL, settings: EncoderProfile.settings)
        newRecorder.isMeteringEnabled = true
        guard newRecorder.prepareToRecord() else {
          _ = newRecorder.deleteRecording()
          try? FileManager.default.removeItem(at: fileURL)
          throw AudioFileManagerError.failedToCreateRecorder
        }
      }
      guard newRecorder.record() else {
        _ = newRecorder.deleteRecording()
        throw AudioFileManagerError.failedToCreateRecorder
      }
      let startDate = Date()
      recorder = newRecorder
      currentRecordingID = id
      currentRecordingStart = startDate
      currentRecordingOwner = owner
      activeInputSession = sessionContext
      if claimed != nil {
        // The staged file was created while the app was idle, so its creation
        // date would otherwise misdate the recording in listings.
        try? FileManager.default.setAttributes([.creationDate: startDate], ofItemAtPath: fileURL.path)
      }
      if owner == .auxiliary {
        self.lifecycleHandler?(.auxiliaryStarted)
      }
      return RecordingStart(url: fileURL, usedWarmRecorder: claimed != nil)
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw AudioFileManagerError.failedToCreateRecorder
    }
  }

  private func claimWarmRecorder(matching context: CaptureWarmContext?) -> StagedRecorder? {
    guard let context, self.warmMachine.claim(for: context) else { return nil }
    guard let staged = self.staged, staged.context == context else { return nil }
    self.staged = nil
    return staged
  }

  func stopRecording() async throws -> RecordingSummary {
    guard let recorder, let recordingID = currentRecordingID, let start = currentRecordingStart else {
      throw AudioFileManagerError.noActiveRecording
    }

    let owner = self.currentRecordingOwner
    recorder.stop()
    self.recorder = nil
    self.currentRecordingStart = nil
    self.currentRecordingID = nil
    self.currentRecordingOwner = nil

    let url = recorder.url
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

    if owner == .auxiliary {
      self.lifecycleHandler?(.auxiliaryEnded)
    }

    return summary
  }

  func cancelRecording(deleteFile: Bool = true) async {
    let session = activeInputSession
    let owner = currentRecordingOwner

    if let recorder {
      recorder.stop()
      let url = recorder.url
      self.recorder = nil
      currentRecordingStart = nil
      currentRecordingID = nil
      currentRecordingOwner = nil
      if deleteFile {
        try? FileManager.default.removeItem(at: url)
      }
    }

    if let session {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
    }

    if owner == .auxiliary {
      self.lifecycleHandler?(.auxiliaryEnded)
    }
  }

  func listRecordings() async -> [RecordingSummary] {
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
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
