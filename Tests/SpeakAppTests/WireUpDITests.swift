import XCTest

@testable import SpeakApp

/// Verifies that WireUp.bootstrap supports dependency injection via BootstrapOptions.
final class WireUpDITests: XCTestCase {

    @MainActor
    func testBootstrap_acceptsCustomSettings() {
        let customSettings = AppSettings()
        customSettings.postProcessingEnabled = false

        let options = WireUp.BootstrapOptions(
            settingsOverride: customSettings
        )
        let env = WireUp.bootstrap(options: options)

        XCTAssertFalse(
            env.settings.postProcessingEnabled,
            "Should use injected settings"
        )
    }

    @MainActor
    func testBootstrap_defaultOptionsMatchesProduction() {
        // Ensure default bootstrap still works (no arguments)
        let env = WireUp.bootstrap()
        XCTAssertNotNil(env.main)
    }

    @MainActor
    func testBootstrap_acceptsCustomPermissions() {
        let customPermissions = PermissionsManager()
        let options = WireUp.BootstrapOptions(
            permissionsOverride: customPermissions
        )
        let env = WireUp.bootstrap(options: options)

        XCTAssertTrue(
            env.permissions === customPermissions,
            "Should use the injected PermissionsManager instance"
        )
    }

    @MainActor
    func testBootstrap_injectedSettingsIsSharedAcrossServices() {
        let customSettings = AppSettings()
        let options = WireUp.BootstrapOptions(
            settingsOverride: customSettings
        )
        let env = WireUp.bootstrap(options: options)

        XCTAssertTrue(
            env.settings === customSettings,
            "Environment should hold the exact injected settings reference"
        )
    }
}
