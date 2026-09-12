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
    nonisolated static let directoryKey = "SPEAK_CORE_JOURNEY_DIRECTORY"
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
            temporaryDirectory: launchDirectory(for: identifier).deletingLastPathComponent(),
            probesHotKey: ProcessInfo.processInfo.environment[hotKeyProbeKey] == "1",
            runsBatchJourney: ProcessInfo.processInfo.environment[batchJourneyKey] == "1"
        )
    }()

    /// XCTest and its launched app may have different process-specific TMPDIRs.
    /// An explicit shared path is restricted to this launch's UUID under /tmp.
    nonisolated static func launchDirectory(for identifier: UUID) -> URL {
        guard let path = ProcessInfo.processInfo.environment[directoryKey] else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("com.justspeaktoit.tests.core-journey.\(identifier.uuidString)")
        }
        guard let directory = validatedSharedDirectory(path, identifier: identifier) else {
            preconditionFailure("SPEAK_CORE_JOURNEY_DIRECTORY must be the UUID-scoped directory under /tmp")
        }
        return directory
    }

    nonisolated static func validatedSharedDirectory(_ path: String, identifier: UUID) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let expected = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("com.justspeaktoit.tests.core-journey.\(identifier.uuidString)", isDirectory: true)
        // URL directory hints differ for nonexistent paths on macOS 15.
        // Compare the resolved filesystem paths, preserving symlink validation.
        return directory.path == expected.path ? directory : nil
    }

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
            // XCTest may hold a globally consumed key for about five seconds
            // while awaiting synthesis acknowledgement from the foreground app.
            settings.holdThreshold = 20
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
            // Consecutive XCUI typeKey calls can be ten seconds apart on macOS.
            settings.doubleTapWindow = 15
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
