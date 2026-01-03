import AVFoundation
import Foundation

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
  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private var recorder: AVAudioRecorder?
  private var currentRecordingID: UUID?
  private var currentRecordingStart: Date?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?

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
  func getCurrentAudioLevel() -> Float {
    guard let recorder = recorder, recorder.isRecording else { return 0 }
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

  func startRecording() async throws -> URL {
    guard recorder == nil else { throw AudioFileManagerError.alreadyRecording }

    let permissionStatus = await MainActor.run { permissionsManager.status(for: .microphone) }
    if !permissionStatus.isGranted {
      let requested = await permissionsManager.request(.microphone)
      guard requested.isGranted else {
        throw AudioFileManagerError.microphonePermissionMissing
      }
    }

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()

    let id = UUID()
    let startDate = Date()
    let directory = await MainActor.run { appSettings.recordingsDirectory }
    let fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).m4a")

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 128_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    do {
      let newRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
      newRecorder.isMeteringEnabled = true
      newRecorder.prepareToRecord()
      newRecorder.record()
      recorder = newRecorder
      currentRecordingID = id
      currentRecordingStart = startDate
      activeInputSession = sessionContext
      return fileURL
    } catch {
      await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
      throw AudioFileManagerError.failedToCreateRecorder
    }
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
