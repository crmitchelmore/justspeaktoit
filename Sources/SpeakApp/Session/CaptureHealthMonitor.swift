import SpeakCore
import Combine
import Foundation

/// Builds the HUD's capture-health row (microphone permission, input device,
/// provider and latency tier) and keeps it current while the HUD shows it.
@MainActor
final class CaptureHealthMonitor {
  private let permissions: PermissionsManager
  private let devices: AudioInputDeviceManager
  private let settings: AppSettings
  private let hud: HUDManager
  private var cancellables: Set<AnyCancellable> = []

  init(
    permissions: PermissionsManager,
    devices: AudioInputDeviceManager,
    settings: AppSettings,
    hud: HUDManager
  ) {
    self.permissions = permissions
    self.devices = devices
    self.settings = settings
    self.hud = hud
  }

  /// Starts pushing fresh snapshots to the HUD while it shows the health row.
  func start() {
    // Push updated snapshot whenever microphone permission changes.
    permissions.$statuses
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the selected input device changes.
    devices.$selectedDeviceUID
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the device list changes (hardware plug/unplug).
    devices.$devices
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the live transcription model changes.
    settings.$liveTranscriptionModel
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot whenever the batch transcription model changes.
    settings.$batchTranscriptionModel
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.pushCaptureHealthIfActive()
      }
      .store(in: &cancellables)

    // Push updated snapshot on every HUD phase transition so all `finishFailure` paths
    // (not just `cleanupAfterFailure`) also receive fresh health data.
    hud.$snapshot
      .map(\.phase)
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] phase in
        guard let self else { return }
        switch phase {
        case .recording, .failure:
          self.hud.updateCaptureHealth(self.snapshot())
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
    let phase = hud.snapshot.phase
    guard case .recording = phase else {
      if case .failure = phase {
        hud.updateCaptureHealth(snapshot())
      }
      return
    }
    hud.updateCaptureHealth(snapshot())
  }

  /// The microphone, device and provider the next capture would use.
  func snapshot() -> CaptureHealthSnapshot {
    let micStatus = permissions.status(for: .microphone)
    let micPermission: CaptureHealthSnapshot.MicrophonePermission
    switch micStatus {
    case .granted:
      micPermission = .granted
    case .denied, .restricted:
      micPermission = .denied
    case .notDetermined:
      micPermission = .notDetermined
    }

    let deviceName = devices.preferredDeviceLabel

    let activeModel: String
    switch settings.transcriptionMode {
    case .liveNative:
      activeModel = settings.liveTranscriptionModel
    case .batchRemote:
      activeModel = settings.batchTranscriptionModel
    case .localModel:
      activeModel = settings.localTranscriptionMode == .streaming
        ? settings.localStreamingModelSource
        : settings.localTranscriptionModel
    }
    let providerLabel = captureHealthProviderLabel(for: activeModel)
    let latencyTier = ModelCatalog.allOptions.first(where: { $0.id == activeModel })?.latencyTier ?? .medium

    return CaptureHealthSnapshot(
      microphonePermission: micPermission,
      noInputDevicesAvailable: devices.devices.isEmpty,
      inputDeviceName: deviceName,
      providerLabel: providerLabel,
      latencyTier: latencyTier
    )
  }

  /// The model the current transcription mode would run.
  var currentTranscriptionModelIdentifier: String {
    switch settings.transcriptionMode {
    case .liveNative:
      return settings.liveTranscriptionModel
    case .batchRemote:
      return settings.batchTranscriptionModel
    case .localModel:
      return settings.localTranscriptionMode == .streaming
        ? settings.localStreamingModelSource
        : settings.localTranscriptionModel
    }
  }

  private func captureHealthProviderLabel(for modelID: String) -> String {
    guard settings.transcriptionMode == .localModel else {
      return ModelCatalog.friendlyName(for: modelID)
    }
    if settings.localTranscriptionMode == .streaming {
      if let batchModelID = WhisperKitStreamingModel.batchModelID(from: modelID),
        let model = LocalModelManager.shared.model(for: batchModelID) {
        return shortLocalModelDisplayName(model.displayName) + " (Streaming)"
      }
      if FluidAudioParakeetModel.matches(modelID) {
        return FluidAudioParakeetModel.displayName
      }
      #if !APP_STORE
      // Prefer the name stored with the streaming source: the slug-based ID is
      // lossy (case, punctuation and path components are rewritten), so
      // re-deriving a label from it can rename a source like "My_ASR.v2".
      if let sourceName = Self.customStreamingSourceName(
        for: modelID,
        in: LocalModelManager.shared.streamingModelSources
      ) {
        return sourceName + " (Streaming)"
      }
      // Legacy fallback for identifiers with no stored source metadata: use
      // the catalogue's cleaned-up name rather than the raw source ID
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

  #if !APP_STORE
  /// Resolves a custom streaming source identifier back to the model name the
  /// user configured for it. Returns `nil` when no stored source matches so
  /// callers can fall back to legacy slug-derived naming.
  nonisolated static func customStreamingSourceName(
    for modelID: String,
    in sources: [LocalStreamingModelSource]
  ) -> String? {
    guard let source = sources.first(where: { $0.id == modelID }) else { return nil }
    let name = source.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
  #endif
}
