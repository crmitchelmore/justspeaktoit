#if DEBUG
import Carbon
import Foundation
import SpeakHotKeys

/// Explicit opt-in for isolated launched-app checks, never a release mode.
/// The batch variant drives production recording orchestration with a prerecorded
/// file source and HTTP fixture. Other variants leave recording disabled.
@MainActor
final class CoreJourneyLaunchProfile {
    nonisolated static let environmentKey = "SPEAK_CORE_JOURNEY_PROFILE"
    nonisolated static let batchJourneyKey = "SPEAK_CORE_JOURNEY_BATCH"
    nonisolated static let hotKeyProbeKey = "SPEAK_CORE_JOURNEY_HOTKEY_PROBE"

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] != nil
    }

    static let current: CoreJourneyLaunchProfile? = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("SPEAK_CORE_JOURNEY_PROFILE must contain a UUID")
        }
        return CoreJourneyLaunchProfile(
            identifier: identifier,
            probesHotKey: ProcessInfo.processInfo.environment[hotKeyProbeKey] == "1",
            runsBatchJourney: ProcessInfo.processInfo.environment[batchJourneyKey] == "1"
        )
    }()

    let defaults: UserDefaults
    let settings: AppSettings
    let fileManager: FileManager
    let directory: URL
    let suiteName: String
    let probesHotKey: Bool
    let runsBatchJourney: Bool
    private var hotKeyProbe: CoreJourneyHotKeyProbe?

    init(
        identifier: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        probesHotKey: Bool = false,
        runsBatchJourney: Bool = false
    ) {
        self.probesHotKey = probesHotKey
        self.runsBatchJourney = runsBatchJourney
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
        if probesHotKey || runsBatchJourney {
            settings.selectedHotKey = .custom(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option, .shift])
            settings.holdThreshold = 5
            settings.doubleTapWindow = 0.1
        }
        if runsBatchJourney {
            settings.transcriptionMode = .batchRemote
            settings.batchTranscriptionModel = CoreJourneyBatchFixture.model
            settings.postProcessingEnabled = false
            settings.textOutputMethod = .clipboardOnly
            settings.restoreClipboardAfterPaste = false
            settings.recordingSoundsEnabled = false
            settings.silenceDetectionEnabled = false
            settings.hotKeyActivationStyle = .doubleTapToggle
            settings.showHUDDuringSessions = false
            settings.voiceCommandsEnabled = false
            settings.postRecordingTailDuration = 0
            settings.historyFlushInterval = 0.2
            settings.doubleTapWindow = 4
        }
    }

    func startHotKeyProbe(manager: HotKeyManager, main: MainManager) {
        guard probesHotKey || runsBatchJourney else { return }
        precondition(hotKeyProbe == nil, "Core journey hotkey probe must start once")
        hotKeyProbe = CoreJourneyHotKeyProbe(
            manager: manager, directory: directory, main: runsBatchJourney ? main : nil
        )
    }

    func bootstrapOptions() -> WireUp.BootstrapOptions {
        WireUp.BootstrapOptions(
            settingsOverride: settings,
            permissionsOverride: runsBatchJourney
                ? PermissionsManager() : PermissionsManager(statusProvider: { _ in .denied }),
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
