import Foundation

/// The steps `startRecording` takes before `record()`: the main-actor
/// preflight (#611), microphone authorisation and the recorder to open.
extension AudioFileManager {
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

  /// Throws unless the microphone may be used, asking only when the status is
  /// not already granted. Returns whether it was granted without asking, the
  /// only case in which a preflight input session is used.
  func authoriseMicrophone(_ preflight: CaptureStartPreflight?) async throws -> Bool {
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
  func prepareRecorder(
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
  func endPreflightInput(_ preflight: CaptureStartPreflight?) async {
    guard let session = preflight?.inputSession else { return }
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}
