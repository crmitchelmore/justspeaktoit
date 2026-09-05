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
        #if DEBUG
        let startsUpdater = !CoreJourneyLaunchProfile.isRequested
        #else
        let startsUpdater = true
        #endif
        return SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
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
        #if DEBUG
        if CoreJourneyLaunchProfile.isRequested { return }
        #endif

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
    /// Apple Silicon Macs follow the arm64 feed; everything else keeps the
    /// universal feed baked into Info.plist (issue #774).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeedSelection.current
    }

    /// Refuse to start an update the staging volume cannot hold.
    ///
    /// Sparkle downloads and extracts under `~/Library/Caches/<bundle id>/
    /// org.sparkle-project.Sparkle/`, so a full volume surfaces as Sparkle's
    /// generic "update error" somewhere mid-pipeline. Throwing here aborts the
    /// update before anything is downloaded and puts our own message — how much
    /// is free, how much is needed — in the alert instead.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        try UpdateDiskSpacePolicy.validateFreeSpace(forEnclosureLength: updateItem.contentLength)
    }

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
