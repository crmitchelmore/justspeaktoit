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
        testSettings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    return WireUp.BootstrapOptions(
        settingsOverride: testSettings,
        permissionsOverride: permissionsOverride,
        keychainServiceOverride: "com.justspeaktoit.tests.wireup.\(UUID().uuidString)"
    )
}
