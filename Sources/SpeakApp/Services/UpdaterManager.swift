import Foundation
import Sparkle

/// Manages automatic updates using Sparkle framework
@MainActor
final class UpdaterManager: ObservableObject {
    /// Shared instance for app-wide access
    static let shared = UpdaterManager()

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

    private init() {
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
}

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
