import AppKit
import Foundation
import SpeakCore

// MARK: - Dependency Injection Options

extension WireUp {
  struct BootstrapOptions {
    var settingsOverride: AppSettings?
    var permissionsOverride: PermissionsManager?
    /// Opens an isolated credential vault under this service instead of the
    /// user's. It has no legacy predecessor and never joins API-key sync, so a
    /// test or launch profile cannot read, copy or sync the user's keys.
    var keychainServiceOverride: String?
    /// Whether to clear the files a pre-warmed recorder staged in an earlier
    /// run. Only the real app does this: staging lives in the user's temporary
    /// folder, which a test or launch profile shares with the real app.
    var sweepsStagedLeftovers = true
    /// Resolves Application Support for history, the personal lexicon,
    /// corrections, Compare Models rounds and analytics state.
    var fileManager: FileManager = .default
    /// Preferences for the stores that do not read `AppSettings`: profiles,
    /// pronunciation, shortcuts, synced-history bookkeeping and speech usage.
    var defaults: UserDefaults = .standard
    /// Process-wide services started once the graph is wired.
    var integrations: Integrations = .live

    static let `default` = BootstrapOptions()

    /// The credential vault this bootstrap opens.
    var credentialStorage: SecureStorageConfiguration {
      keychainServiceOverride.map(SecureAppStorage.isolatedConfiguration(service:))
        ?? SecureAppStorage.productionConfiguration
    }

    /// Whether this bootstrap starts encrypted API-key sync on `channel`. Only
    /// the user's own vault may: the shared sync pairs it with this Mac's sync
    /// state and the user's private CloudKit database.
    func startsCredentialKeySync(on channel: DistributionChannel) -> Bool {
      keychainServiceOverride == nil && channel.supportsEncryptedCloudKitKeySync
    }
  }

  /// The services a bootstrap reaches beyond the app's own objects. The app
  /// uses `.live`; a test injects its own so bootstrap never syncs the
  /// developer's iCloud account, registers for or posts notifications, or
  /// sends analytics.
  struct Integrations {
    /// Starts CloudKit history and Compare Models sync, and remote-transcript
    /// delivery, which registers its notification actions and re-runs sync
    /// on wake and activation.
    var startCloudSync: @MainActor (MacHistorySyncAdapter, MacComparisonSyncAdapter, RemoteTranscriptDelivery) -> Void
    /// Builds product analytics over the bootstrap's storage, or nil when absent.
    var makeAnalytics: @MainActor (AppSettings, FileManager) -> AnalyticsServices?

    static let live = Integrations(
      startCloudSync: { history, comparisons, remoteTranscripts in
        #if APP_STORE
        NSApp.registerForRemoteNotifications()
        #endif
        remoteTranscripts.start()
        Task {
          await history.start()
          // After the history engine, which owns zone creation for the shared zone.
          await comparisons.start()
        }
      },
      makeAnalytics: WireUp.makeAnalyticsController(settings:fileManager:)
    )
  }

  // MARK: - Credential Vault Factory

  /// Opens the credential vault a bootstrap with `options` uses.
  static func buildSecureStorage(
    options: BootstrapOptions,
    settings: AppSettings,
    permissions: PermissionsManager
  ) -> SecureAppStorage {
    SecureAppStorage(
      permissionsManager: permissions,
      appSettings: settings,
      configuration: options.credentialStorage
    )
  }
}
