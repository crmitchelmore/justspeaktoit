import Foundation
import SpeakCore
import SpeakHotKeys

/// Values derived from the stored preferences: what the selected models can do
/// and which optional behaviours are actually in effect on this Mac.
extension AppSettings {
  /// True once the user has explicitly chosen a live transcription model.
  /// Launch-time auto-configuration checks this so a default can only fill a
  /// gap, never replace a real choice.
  var hasExplicitLiveTranscriptionModelChoice: Bool {
    migrationDefaults.object(forKey: DefaultsKey.liveTranscriptionModel.rawValue) != nil
  }

  var preferredModelLanguage: String? {
    TranscriptionLanguageCatalog.providerLanguage(for: preferredLocaleIdentifier)
  }

  var resolvedPreferredLocaleIdentifier: String {
    TranscriptionLanguageCatalog.localeIdentifier(for: preferredLocaleIdentifier)
  }

  /// Whether the status bar icon should currently be visible given the active
  /// visibility mode. In menu bar modes the icon is essential; in Dock Only
  /// mode it is governed by `showStatusBarIconInDockOnly` (on by default).
  var shouldShowStatusBarIcon: Bool {
    switch appVisibility {
    case .dockAndMenuBar, .menuBarOnly:
      return true
    case .dockOnly:
      return showStatusBarIconInDockOnly
    }
  }

  var hasConfiguredGlobalHotKey: Bool {
    isGlobalHotKeyConfigured(for: ReleaseTrain.current)
  }

  func isGlobalHotKeyConfigured(for train: ReleaseTrain) -> Bool {
    train == .stable || migrationDefaults.bool(forKey: "alphaGlobalHotKeyExplicitlyChosen")
  }

  func chooseGlobalHotKey(_ hotKey: HotKey) {
    migrationDefaults.set(true, forKey: "alphaGlobalHotKeyExplicitlyChosen")
    selectedHotKey = hotKey
  }

  /// Whether hands-free dictation can actually run on this machine.
  var handsFreeDictationSupported: Bool {
    AppleLocalModels.supportsSpeechDetector
  }

  /// The setting only takes effect where the detector exists, so an enabled
  /// setting carried over from a newer OS cannot change behaviour on an older one.
  var handsFreeDictationActive: Bool {
    handsFreeDictationEnabled
      && handsFreeDictationSupported
      && HandsFreeDictationPolicy.supportsCapture(
        modelID: liveTranscriptionModel,
        isStreaming: transcriptionMode == .liveNative
      )
  }

  /// Per-model capability lookup for the currently selected live model.
  var liveModelCapabilities: LiveModelCapabilities {
    guard transcriptionMode == .liveNative else { return .default }
    return ModelCatalog.liveCapabilities(for: liveTranscriptionModel)
  }

  /// Whether the currently selected live model supports the given speed mode.
  func supports(speedMode mode: SpeedMode) -> Bool {
    liveModelCapabilities.supportedSpeedModes.contains(mode.coreID)
  }

  var isAssemblyAIModel: Bool {
    liveTranscriptionModel.contains("assemblyai")
  }

  var isActiveAssemblyAILiveModel: Bool {
    transcriptionMode == .liveNative && isAssemblyAIModel
  }

  var hasSelectedModulateModel: Bool {
    [liveTranscriptionModel, batchTranscriptionModel].contains { $0.split(separator: "/").first?.caseInsensitiveCompare("modulate") == .orderedSame } // swiftlint:disable:this line_length
  }

  /// True when the model that will actually run — streaming or remote batch —
  /// is a Meta Muse Voice Transcribe model, so its bias options apply.
  var hasSelectedMetaMuseModel: Bool {
    let selected: String
    switch transcriptionMode {
    case .liveNative: selected = liveTranscriptionModel
    case .batchRemote: selected = batchTranscriptionModel
    case .localModel: return false
    }
    return selected.split(separator: "/").first?
      .caseInsensitiveCompare(MetaMuseVoiceTranscribe.providerID) == .orderedSame
  }
}
