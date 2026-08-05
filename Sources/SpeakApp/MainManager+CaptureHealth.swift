import SpeakCore
import Combine
import Foundation

extension MainManager {
  // MARK: - Capture Health

  func setupCaptureHealthBindings() {
    // Push updated snapshot whenever microphone permission changes.
    permissionsManager.$statuses
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the selected input device changes.
    audioInputDeviceManager.$selectedDeviceUID
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the device list changes (hardware plug/unplug).
    audioInputDeviceManager.$devices
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the live transcription model changes.
    appSettings.$liveTranscriptionModel
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the batch transcription model changes.
    appSettings.$batchTranscriptionModel
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot on every HUD phase transition so all `finishFailure` paths
    // (not just `cleanupAfterFailure`) also receive fresh health data.
    hudManager.$snapshot
      .map(\.phase)
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] phase in
        guard let self else { return }
        switch phase {
        case .recording, .failure:
          self.hudManager.updateCaptureHealth(self.buildCaptureHealthSnapshot())
        default:
          break
        }
      }
      .store(in: &cancellables)
  }

  /// Rebuild and forward a `CaptureHealthSnapshot` only when the HUD is visible in a
  /// phase that renders the health row (recording or failure). This avoids unnecessary
  /// snapshot builds during idle / transcribing / delivering phases.
  private func pushCaptureHealthIfActive() {
    let phase = hudManager.snapshot.phase
    guard case .recording = phase else {
      if case .failure = phase {
        hudManager.updateCaptureHealth(buildCaptureHealthSnapshot())
      }
      return
    }
    hudManager.updateCaptureHealth(buildCaptureHealthSnapshot())
  }

  /// Builds a `CaptureHealthSnapshot` from the current manager state.
  func buildCaptureHealthSnapshot() -> CaptureHealthSnapshot {
    let micStatus = permissionsManager.status(for: .microphone)
    let micPermission: CaptureHealthSnapshot.MicrophonePermission
    switch micStatus {
    case .granted:
      micPermission = .granted
    case .denied, .restricted:
      micPermission = .denied
    case .notDetermined:
      micPermission = .notDetermined
    }

    let deviceName = audioInputDeviceManager.currentSelectionDisplayName

    let activeModel: String
    switch appSettings.transcriptionMode {
    case .liveNative:
      activeModel = appSettings.liveTranscriptionModel
    case .batchRemote:
      activeModel = appSettings.batchTranscriptionModel
    case .localModel:
      activeModel = appSettings.localTranscriptionMode == .streaming
        ? appSettings.localStreamingModelSource
        : appSettings.localTranscriptionModel
    }
    let providerLabel = captureHealthProviderLabel(for: activeModel)
    let latencyTier = ModelCatalog.allOptions.first(where: { $0.id == activeModel })?.latencyTier ?? .medium

    return CaptureHealthSnapshot(
      microphonePermission: micPermission,
      noInputDevicesAvailable: audioInputDeviceManager.devices.isEmpty,
      inputDeviceName: deviceName,
      providerLabel: providerLabel,
      latencyTier: latencyTier
    )
  }

  private func currentTranscriptionModelIdentifier() -> String {
    switch appSettings.transcriptionMode {
    case .liveNative:
      return appSettings.liveTranscriptionModel
    case .batchRemote:
      return appSettings.batchTranscriptionModel
    case .localModel:
      return appSettings.localTranscriptionMode == .streaming
        ? appSettings.localStreamingModelSource
        : appSettings.localTranscriptionModel
    }
  }

  func makeHistoryDiagnosticContext() -> HistoryDiagnosticContext {
    let health = buildCaptureHealthSnapshot()
    let info = Bundle.main.infoDictionary
    let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let appBuild = info?["CFBundleVersion"] as? String ?? "unknown"
    let microphonePermission: String
    switch health.microphonePermission {
    case .granted:
      microphonePermission = "granted"
    case .denied:
      microphonePermission = "denied"
    case .notDetermined:
      microphonePermission = "notDetermined"
    }

    return HistoryDiagnosticContext(
      appVersion: appVersion,
      appBuild: appBuild,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      processIdentifier: Int(ProcessInfo.processInfo.processIdentifier),
      microphonePermission: microphonePermission,
      inputDeviceName: health.inputDeviceName,
      providerLabel: health.providerLabel,
      latencyTier: health.latencyTier.displayName,
      transcriptionMode: appSettings.effectiveTranscriptionModeDisplayName,
      transcriptionModel: currentTranscriptionModelIdentifier(),
      postProcessingModel: appSettings.postProcessingModel,
      speedMode: appSettings.speedMode.displayName
    )
  }

  func attachFailureDiagnostics(to session: ActiveSession) {
    session.diagnosticContext = makeHistoryDiagnosticContext()
    let description = "Diagnostic snapshot captured for issue report"
    if !session.events.contains(where: { $0.kind == .error && $0.description == description }) {
      session.events.append(HistoryEvent(kind: .error, description: description))
    }
  }

  private func captureHealthProviderLabel(for modelID: String) -> String {
    guard appSettings.transcriptionMode == .localModel else {
      return ModelCatalog.friendlyName(for: modelID)
    }
    if appSettings.localTranscriptionMode == .streaming {
      if let batchModelID = WhisperKitStreamingModel.batchModelID(from: modelID),
        let model = LocalModelManager.shared.model(for: batchModelID) {
        return shortLocalModelDisplayName(model.displayName) + " (Streaming)"
      }
      if FluidAudioParakeetModel.matches(modelID) {
        return FluidAudioParakeetModel.displayName
      }
      #if !APP_STORE
      // Use the catalogue's cleaned-up name rather than the raw source ID
      // (e.g. "sherpa-onnx-streaming-zipformer-en-2023-06-26") so the HUD
      // capture-health label stays readable.
      return ModelCatalog.friendlyName(for: modelID)
      #else
      return "Local Streaming"
      #endif
    }
    guard let localModel = LocalModelManager.shared.model(for: modelID) else {
      return ModelCatalog.friendlyName(for: modelID)
    }
    return shortLocalModelDisplayName(localModel.displayName)
  }

  private func shortLocalModelDisplayName(_ displayName: String) -> String {
    let suffixRange = displayName.range(of: " from ", options: [.caseInsensitive, .backwards])
    guard let suffixRange else { return displayName }
    return String(displayName[..<suffixRange.lowerBound])
  }
}
