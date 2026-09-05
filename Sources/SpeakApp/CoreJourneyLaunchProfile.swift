#if DEBUG
import Foundation

/// Explicit opt-in for the launched-app bootstrap check, never a release mode.
/// The real managers/views are built; recording and external startup work stay
/// disabled until native capture/permission coverage is implemented separately.
@MainActor
final class CoreJourneyLaunchProfile {
    nonisolated static let environmentKey = "SPEAK_CORE_JOURNEY_PROFILE"

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] != nil
    }

    static let current: CoreJourneyLaunchProfile? = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("SPEAK_CORE_JOURNEY_PROFILE must contain a UUID")
        }
        return CoreJourneyLaunchProfile(identifier: identifier)
    }()

    let defaults: UserDefaults
    let settings: AppSettings
    let fileManager: FileManager
    let directory: URL
    let suiteName: String

    init(identifier: UUID, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let suiteName = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let directory = temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated core journey defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.suiteName = suiteName
        self.directory = directory
        self.defaults = defaults
        fileManager = CoreJourneyFileManager(directory: directory)

        // Supply typed values before any manager can observe the settings. String
        // launch arguments do not satisfy AppSettings' NSNumber/Bool casts.
        for key in [
            "audioPreWarmingEnabled", "connectionPreWarmingEnabled", "handsFreeDictationEnabled",
            "enableSendToMac", "enableAutomationServer", "analyticsEnabled"
        ] {
            defaults.set(false, forKey: key)
        }
        defaults.set(directory.appendingPathComponent("Recordings").path, forKey: "recordingsDirectory")
        settings = AppSettings(defaults: defaults)
    }

    func bootstrapOptions() -> WireUp.BootstrapOptions {
        WireUp.BootstrapOptions(
            settingsOverride: settings,
            permissionsOverride: PermissionsManager(statusProvider: { _ in .denied }),
            keychainServiceOverride: suiteName,
            sweepsStagedLeftovers: false
        )
    }
}

private final class CoreJourneyFileManager: FileManager, @unchecked Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .applicationSupportDirectory
            ? [self.directory]
            : super.urls(for: directory, in: domainMask)
    }
}
#endif
