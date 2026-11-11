import Combine
import SwiftUI

/// Live recording state for the main window's record controls.
///
/// Views used to read `environment.main.state` while observing only
/// `AppEnvironment`, which never republishes `MainManager` changes. A recording
/// started from the hotkey, menu bar, CLI or Shortcuts therefore left the
/// toolbar showing "Record". This model mirrors only `MainManager.state`
/// (deduplicated), so record controls track every session without the window
/// re-rendering for each live-preview update.
@MainActor
final class RecordingControlModel: ObservableObject {
  @Published private(set) var state: MainManager.State = .idle

  private let toggleAction: @MainActor () -> Void
  private var stateSubscription: AnyCancellable?

  init<StatePublisher: Publisher>(
    statePublisher: StatePublisher,
    toggle: @escaping @MainActor () -> Void
  ) where StatePublisher.Output == MainManager.State, StatePublisher.Failure == Never {
    toggleAction = toggle
    // `@Published` replays its current value on subscription, so a window opened
    // mid-recording starts in the right state.
    stateSubscription = statePublisher
      .removeDuplicates()
      .sink { [weak self] state in
        MainActor.assumeIsolated { self?.state = state }
      }
  }

  convenience init(main: MainManager) {
    self.init(statePublisher: main.$state) { [weak main] in main?.toggleRecordingFromUI() }
  }

  var isRecording: Bool { state == .recording }

  /// Processing and delivery cannot be interrupted from a record control.
  var isBusy: Bool {
    switch state {
    case .processing, .delivering:
      return true
    case .idle, .recording, .completed, .failed:
      return false
    }
  }

  var accessibility: RecordingControlAccessibility {
    RecordingControlAccessibility(state: state)
  }

  /// Starts a recording, or stops the active one however it was started.
  func toggle() {
    toggleAction()
  }
}
