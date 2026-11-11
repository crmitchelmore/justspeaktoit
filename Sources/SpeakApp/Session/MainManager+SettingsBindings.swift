import SpeakCore
import Combine
import Foundation

extension MainManager {
  /// Keeps the sound profile, hands-free arming and the offered delivery
  /// remedy in step with settings and permissions.
  func bindSettings() {
    recordingSoundPlayer.profile = appSettings.recordingSoundProfile
    appSettings.$recordingSoundProfile
      .receive(on: RunLoop.main)
      .sink { [weak self] profile in
        self?.recordingSoundPlayer.profile = profile
      }
      .store(in: &cancellables)

    // Turning hands-free off or selecting an incompatible transcription route
    // must tear down a live detector, not just stop future arming.
    Publishers.CombineLatest3(
      appSettings.$handsFreeDictationEnabled,
      appSettings.$transcriptionMode,
      appSettings.$liveTranscriptionModel
    )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.disarmHandsFreeIfDisabled()
      }
      .store(in: &cancellables)

    // @Published emits before the value is stored; hopping to the run loop
    // lets the reconciliation read the new settings.
    Publishers.CombineLatest4(
      appSettings.$appSwitchDelivery,
      appSettings.$textOutputMethod,
      appSettings.$streamingInsertionEnabled,
      permissionsManager.$statuses
    )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.reconcilePendingDeliveryRemedy()
      }
      .store(in: &cancellables)
  }
}
