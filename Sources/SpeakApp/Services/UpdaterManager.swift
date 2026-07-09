import Combine
import Foundation
import SpeakCore
#if !APP_STORE
import Sparkle
#endif

/// Manages app update capabilities for the current distribution channel.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    /// Shared instance for app-wide access
    static let shared = UpdaterManager()

#if !APP_STORE
    /// The Sparkle updater controller
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    /// Whether automatic update checks are enabled
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Whether the updater can check for updates (e.g., not already checking)
    @Published private(set) var canCheckForUpdates = false

    @Published private(set) var latestVersion: String?

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private override init() {
        automaticallyChecksForUpdates = false
        super.init()
        _ = updaterController

        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates

        // Observe canCheckForUpdates changes
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manually trigger an update check
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Access the underlying updater for SwiftUI integration
    var updater: SPUUpdater {
        updaterController.updater
    }
#else
    /// App Store builds receive updates through the Mac App Store.
    @Published var automaticallyChecksForUpdates = false

    /// Manual update checks are unavailable in App Store builds.
    @Published private(set) var canCheckForUpdates = false

    @Published private(set) var latestVersion: String?

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private override init() {
        super.init()
        latestVersion = currentVersion
    }

    /// App Store builds use the Mac App Store update flow.
    func checkForUpdates() {}
#endif

    var supportsSelfUpdate: Bool {
        DistributionChannel.current.supportsSelfUpdate
    }

    var allowsCrossChannelMessaging: Bool {
        DistributionChannel.current.allowsCrossChannelMessaging
    }

    var updateStatusMessage: String {
        supportsSelfUpdate ? "Latest unknown" : "Updates are delivered through the App Store."
    }
}

#if !APP_STORE
extension UpdaterManager: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.latestVersion = item.displayVersionString
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.latestVersion = self.currentVersion
        }
    }
}
#endif
