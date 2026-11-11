import AppKit
import Foundation

/// Tracks whether the app's windows are hidden behind others while recording,
/// so the 30 Hz audio meter can skip HUD updates nobody can see.
@MainActor
final class HUDOcclusionObserver {
  private(set) var isOccluded = false
  private let notificationCenter: NotificationCenter
  private let isAppVisible: @MainActor () -> Bool
  private var token: NSObjectProtocol?

  /// `isAppVisible` defaults to the application's occlusion state.
  init(
    notificationCenter: NotificationCenter = .default,
    isAppVisible: (@MainActor () -> Bool)? = nil
  ) {
    self.notificationCenter = notificationCenter
    self.isAppVisible = isAppVisible ?? { NSApp.occlusionState.contains(.visible) }
  }

  /// Starts (or restarts) observing; repeated starts never stack observers.
  func start() {
    isOccluded = !isAppVisible()
    removeObserver()
    token = notificationCenter.addObserver(
      forName: NSApplication.didChangeOcclusionStateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isOccluded = !self.isAppVisible()
      }
    }
  }

  func stop() {
    isOccluded = false
    removeObserver()
  }

  private func removeObserver() {
    guard let token else { return }
    notificationCenter.removeObserver(token)
    self.token = nil
  }
}
