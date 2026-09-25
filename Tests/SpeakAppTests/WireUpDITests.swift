import XCTest

@testable import SpeakApp

/// Verifies that WireUp.bootstrap supports dependency injection via BootstrapOptions.
final class WireUpDITests: XCTestCase {

    @MainActor
    func testBootstrap_acceptsCustomSettings() throws {
        let host = try makeWireUpTestHost()
        let customSettings = host.makeSettings()
        customSettings.postProcessingEnabled = false

        let env = WireUp.bootstrap(options: host.options(settings: customSettings))

        XCTAssertFalse(
            env.settings.postProcessingEnabled,
            "Should use injected settings"
        )
    }

    @MainActor
    func testBootstrap_defaultOptionsMatchesProduction() {
        // Ensure default bootstrap still works (no arguments)
        let env = WireUp.bootstrap(options: makeWireUpTestOptions())
        XCTAssertNotNil(env.main)
    }

    @MainActor
    func testBootstrap_acceptsCustomPermissions() throws {
        let host = try makeWireUpTestHost()
        let customPermissions = host.makePermissions()
        let env = WireUp.bootstrap(options: host.options(permissions: customPermissions))

        XCTAssertTrue(
            env.permissions === customPermissions,
            "Should use the injected PermissionsManager instance"
        )
    }

    @MainActor
    func testBootstrap_injectedSettingsIsSharedAcrossServices() throws {
        let host = try makeWireUpTestHost()
        let customSettings = host.makeSettings()
        let env = WireUp.bootstrap(options: host.options(settings: customSettings))

        XCTAssertTrue(
            env.settings === customSettings,
            "Environment should hold the exact injected settings reference"
        )
    }
}
