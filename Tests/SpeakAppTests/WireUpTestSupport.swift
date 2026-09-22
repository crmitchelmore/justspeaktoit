import Foundation

@testable import SpeakApp

@MainActor
func makeWireUpTestOptions(
    settingsOverride: AppSettings? = nil,
    permissionsOverride: PermissionsManager? = nil
) -> WireUp.BootstrapOptions {
    let testSettings: AppSettings
    if let settingsOverride {
        testSettings = settingsOverride
    } else {
        let suite = "WireUpTests-\(UUID().uuidString)"
        // Fail closed: a test must never fall back to the real preferences.
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Could not create isolated WireUp test defaults")
        }
        testSettings = AppSettings(defaults: defaults)
    }

    return WireUp.BootstrapOptions(
        settingsOverride: testSettings,
        permissionsOverride: permissionsOverride,
        // Opens an isolated vault: it never reads or imports the user's keys
        // and never starts encrypted API-key sync (CredentialVaultIsolationTests).
        keychainServiceOverride: "com.justspeaktoit.tests.wireup.\(UUID().uuidString)",
        // A test suite carries no recordings directory of its own, so settings
        // resolve the user's real one. Tests must never sweep it.
        sweepsStagedLeftovers: false
    )
}
