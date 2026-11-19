import Combine
import Foundation
import SpeakCore

/// Pre-warms the post-processing connection at launch, and again whenever the
/// setting or microphone permission changes to allow it, so the first polish
/// does not pay TLS setup.
@MainActor
final class ConnectionPrewarmer {
  private let settings: AppSettings
  private let permissions: PermissionsManager
  private let warmUp: @Sendable () async -> Void
  private var cancellable: AnyCancellable?

  init(settings: AppSettings, permissions: PermissionsManager, warmUp: @escaping @Sendable () async -> Void) {
    self.settings = settings
    self.permissions = permissions
    self.warmUp = warmUp
  }

  convenience init(settings: AppSettings, permissions: PermissionsManager, client: OpenRouterAPIClient) {
    self.init(settings: settings, permissions: permissions) { await client.warmUp() }
  }

  /// Re-warms when pre-warming is switched on or the microphone is granted.
  func observeChanges() {
    cancellable = Publishers.CombineLatest(
      settings.$connectionPreWarmingEnabled,
      permissions.$statuses.map { $0[.microphone]?.isGranted == true }
    )
    .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
    .dropFirst()
    .receive(on: RunLoop.main)
    .sink { [weak self] enabled, permissionGranted in
      guard enabled, permissionGranted else { return }
      self?.warmUpIfEnabled()
    }
  }

  /// Warms the connection in the background when the setting and the
  /// microphone permission allow it. Returns whether it started.
  @discardableResult
  func warmUpIfEnabled() -> Bool {
    guard settings.connectionPreWarmingEnabled else { return false }
    guard permissions.status(for: .microphone).isGranted else { return false }
    let warmUp = warmUp
    Task.detached {
      await warmUp()
    }
    return true
  }
}
