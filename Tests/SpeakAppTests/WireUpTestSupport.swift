import AppKit
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Owned storage and recorded integrations for WireUp bootstrap tests.
///
/// Bootstrap still builds and wires the real service graph. A host gives it one
/// temporary root for everything that resolves Application Support, one
/// preferences suite for settings and the stores that keep their own defaults,
/// denied permissions, an isolated credential vault, and integrations that
/// record what bootstrap asked for instead of syncing iCloud, registering
/// notifications, reporting analytics, changing the test runner's Dock
/// presence or touching login items. Teardown removes the root and the suite
/// and refuses anything else.
@MainActor
final class WireUpTestHost {
    /// Every host's root and preferences suite carry this prefix.
    nonisolated static let namePrefix = "com.justspeaktoit.tests.wireup-host."

    /// The adapters bootstrap asked the integrations to start.
    struct CloudSyncStart {
        let history: MacHistorySyncAdapter
        let comparisons: MacComparisonSyncAdapter
        let remoteTranscripts: RemoteTranscriptDelivery
    }

    let name: String
    let root: URL
    let defaults: UserDefaults
    let fileManager: FileManager
    private(set) var cloudSyncStarts: [CloudSyncStart] = []
    private(set) var analyticsRequests = 0
    private(set) var activationPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var loginItemRequests: [Bool] = []

    init() throws {
        name = Self.namePrefix + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        guard let defaults = UserDefaults(suiteName: name) else {
            throw WireUpTestHostError.unavailableDefaults(name)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        self.defaults = defaults
        fileManager = OwnedRootFileManager(root: root)
        // Typed values first, as the core-journey launch profile does: nothing
        // warms capture, opens a listener or reports analytics, and a Dock-only
        // app without a menu bar icon keeps EnvironmentHolder from adding one.
        let disabled: [AppSettings.DefaultsKey] = [
            .audioPreWarmingEnabled, .connectionPreWarmingEnabled, .handsFreeDictationEnabled,
            .enableSendToMac, .enableAutomationServer, .analyticsEnabled, .showStatusBarIconInDockOnly
        ]
        for key in disabled {
            defaults.set(false, forKey: key.rawValue)
        }
        defaults.set(
            AppSettings.AppVisibility.dockOnly.rawValue,
            forKey: AppSettings.DefaultsKey.appVisibility.rawValue
        )
    }

    /// The app's own folder inside this host's Application Support.
    var appSupportDirectory: URL {
        root.appendingPathComponent(OwnedRootFileManager.applicationSupport, isDirectory: true)
            .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
    }

    /// Settings over this host's preferences and root. Their Dock and
    /// login-item effects are recorded, never applied.
    func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            system: AppSettings.SystemDependencies(
                fileManager: fileManager,
                setActivationPolicy: { [weak self] policy in self?.activationPolicies.append(policy) },
                registerLoginItem: { [weak self] enabled in self?.loginItemRequests.append(enabled) }
            )
        )
    }

    /// Permissions that report `status` (denied by default, so nothing at
    /// bootstrap asks TCC for anything) and keep grant history in this host's
    /// preferences.
    func makePermissions(
        status: @escaping (PermissionType) -> PermissionStatus = { _ in .denied }
    ) -> PermissionsManager {
        PermissionsManager(statusProvider: status, grantHistory: defaults)
    }

    /// Bootstrap options over this host. Settings must come from `makeSettings()`.
    func options(settings: AppSettings? = nil, permissions: PermissionsManager? = nil) -> WireUp.BootstrapOptions {
        let settings = settings ?? makeSettings()
        precondition(settings.migrationDefaults === defaults, "Bootstrap settings must use this host's preferences")
        return WireUp.BootstrapOptions(
            settingsOverride: settings,
            permissionsOverride: permissions ?? makePermissions(),
            // Opens an isolated vault: it never reads or imports the user's keys
            // and never starts encrypted API-key sync (CredentialVaultIsolationTests).
            keychainServiceOverride: "com.justspeaktoit.tests.wireup.\(UUID().uuidString)",
            // The sweep scans the staging folder the real app shares in the
            // user's temporary directory, so only the real app runs it.
            sweepsStagedLeftovers: false,
            fileManager: fileManager,
            defaults: defaults,
            integrations: WireUp.Integrations(
                startCloudSync: { [weak self] history, comparisons, remoteTranscripts in
                    self?.cloudSyncStarts.append(
                        CloudSyncStart(history: history, comparisons: comparisons, remoteTranscripts: remoteTranscripts)
                    )
                },
                makeAnalytics: { [weak self] _, _ in
                    self?.analyticsRequests += 1
                    return nil
                }
            )
        )
    }

    /// Removes this host's preferences suite and root. Fails closed: a name or
    /// directory that is not this host's own is reported and left in place.
    func tearDown() throws {
        guard Self.owns(root: root, name: name) else {
            throw WireUpTestHostError.notOwned(root.path)
        }
        UserDefaults.standard.removePersistentDomain(forName: name)
        try FileManager.default.removeItem(at: root)
    }

    /// Whether `root` is a host's own directory: named `name`, which carries the
    /// host prefix, directly inside this process's temporary folder.
    nonisolated static func owns(root: URL, name: String) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.resolvingSymlinksInPath().standardizedFileURL
        return name.hasPrefix(namePrefix)
            && name.count > namePrefix.count
            && candidate.lastPathComponent == name
            && candidate.deletingLastPathComponent().standardizedFileURL.path == temporary.path
    }
}

enum WireUpTestHostError: Error, CustomStringConvertible {
    case unavailableDefaults(String)
    case notOwned(String)

    var description: String {
        switch self {
        case .unavailableDefaults(let name): "Could not open the preferences suite \(name)"
        case .notOwned(let path): "Refusing to remove \(path): it is not a WireUp test host's own directory"
        }
    }
}

/// Resolves every search-path directory, and the home directory, inside one
/// owned root, so nothing a bootstrap resolves through it reaches the
/// developer's own folders.
private final class OwnedRootFileManager: FileManager {
    static let applicationSupport = "Application Support"

    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        let name = directory == .applicationSupportDirectory
            ? Self.applicationSupport : "SearchPath-\(directory.rawValue)"
        return [root.appendingPathComponent(name, isDirectory: true)]
    }

    override var homeDirectoryForCurrentUser: URL {
        root.appendingPathComponent("Home", isDirectory: true)
    }
}

extension XCTestCase {
    /// A host whose root and preferences suite are removed when the test ends.
    @MainActor
    func makeWireUpTestHost() throws -> WireUpTestHost {
        let host = try WireUpTestHost()
        addTeardownBlock { @MainActor in try host.tearDown() }
        return host
    }

    /// Bootstrap options over a fresh host, for tests that need nothing else from it.
    @MainActor
    func makeWireUpTestOptions() -> WireUp.BootstrapOptions {
        do {
            return try makeWireUpTestHost().options()
        } catch {
            // Fail closed: never fall back to the developer's storage.
            preconditionFailure("Could not create an owned WireUp test host: \(error)")
        }
    }
}
