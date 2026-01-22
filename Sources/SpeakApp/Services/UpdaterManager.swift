import Foundation
import Sparkle

/// Manages automatic updates using Sparkle framework
@MainActor
final class UpdaterManager: ObservableObject {
    /// Shared instance for app-wide access
    static let shared = UpdaterManager()

    /// The Sparkle updater controller
    private let updaterController: SPUStandardUpdaterController

    /// Whether automatic update checks are enabled
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Whether the updater can check for updates (e.g., not already checking)
    @Published private(set) var canCheckForUpdates = false

    private init() {
        // Initialize Sparkle updater
        // startingUpdater: true means it will automatically check on launch per settings
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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
