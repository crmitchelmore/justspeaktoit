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

actor AudioFileManager {
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
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var staged: StagedRecorder?
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
  /// - Returns: `true` when a recorder was staged for `context`.
  func prepareWarmRecorder(for context: CaptureWarmContext) -> Bool {
    guard self.recorder == nil, context.isWarmable else { return false }
    if let staged = self.staged {
      guard staged.context != context else { return true }
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
      warmRecorder.prepareToRecord()
      self.staged = StagedRecorder(context: context, recorder: warmRecorder, id: id, url: fileURL)
      return true
    } catch {
      self.logger.debug("Capture pre-warm failed; falling back to cold start")
      try? FileManager.default.removeItem(at: fileURL)
      return false
    }
  }

  /// Tears the staged recorder down and removes the empty file it created.
  func discardWarmRecorder() {
    guard let staged = self.staged else { return }
    self.staged = nil
    _ = staged.recorder.deleteRecording()
    try? FileManager.default.removeItem(at: staged.url)
  }

  // MARK: - Recording

  /// Starts capture, claiming the staged recorder when `warmContext` matches
  /// the one it was prepared for. On the warm path the only work left on the
  /// hotkey→capture path is the input-device session and `record()` itself.
  func startRecording(warmContext: CaptureWarmContext? = nil) async throws -> URL {
    guard recorder == nil else { throw AudioFileManagerError.alreadyRecording }

    let permissionStatus = await MainActor.run {
      permissionsManager.refresh(.microphone)
      return permissionsManager.status(for: .microphone)
    }
    if !permissionStatus.isGranted {
      self.discardWarmRecorder()
      let requested = await permissionsManager.request(.microphone)
      guard requested.isGranted else {
        throw AudioFileManagerError.microphonePermissionMissing
      }
    }

    let claimed = self.claimWarmRecorder(matching: warmContext)
    // A staged recorder the starting session cannot use is stale by definition:
    // discard it rather than leave an orphaned file behind.
    if claimed == nil { self.discardWarmRecorder() }

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
        newRecorder.prepareToRecord()
      }
      newRecorder.record()
      let startDate = Date()
      recorder = newRecorder
      currentRecordingID = id
      currentRecordingStart = startDate
      activeInputSession = sessionContext
      if claimed != nil {
        // The staged file was created while the app was idle, so its creation
        // date would otherwise misdate the recording in listings.
        try? FileManager.default.setAttributes(
          [.creationDate: startDate], ofItemAtPath: fileURL.path
        )
      }
      return fileURL
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw AudioFileManagerError.failedToCreateRecorder
    }
  }

  private func claimWarmRecorder(matching context: CaptureWarmContext?) -> StagedRecorder? {
    guard let context, let staged = self.staged, staged.context == context else { return nil }
    self.staged = nil
    return staged
  }

  func stopRecording() async throws -> RecordingSummary {
    guard let recorder, let currentRecordingID, let start = currentRecordingStart else {
      throw AudioFileManagerError.noActiveRecording
    }

    recorder.stop()
    self.recorder = nil
    currentRecordingStart = nil

    let url = recorder.url
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let measuredDuration = recorder.currentTime
    let preciseDuration = (try? AVAudioPlayer(contentsOf: url).duration) ?? measuredDuration
    let duration =
      preciseDuration.isFinite && preciseDuration > 0 ? preciseDuration : measuredDuration

    let summary = RecordingSummary(
      id: currentRecordingID,
      url: url,
      startedAt: start,
      duration: duration,
      fileSize: fileSize
    )

    if let session = activeInputSession {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
    }

    return summary
  }

  func cancelRecording(deleteFile: Bool = true) async {
    let session = activeInputSession

    if let recorder {
      recorder.stop()
      let url = recorder.url
      self.recorder = nil
      currentRecordingStart = nil
      currentRecordingID = nil
      if deleteFile {
        try? FileManager.default.removeItem(at: url)
      }
    }

    if let session {
      await audioDeviceManager.endUsingPreferredInput(session: session)
      activeInputSession = nil
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
}
