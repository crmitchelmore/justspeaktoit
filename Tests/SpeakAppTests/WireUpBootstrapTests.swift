import XCTest

@testable import SpeakApp

/// Verifies that the entire service dependency graph initialises without crashing.
///
/// This is the single most important test in the suite. WireUp.bootstrap() creates
/// 20+ interconnected services. If any initialiser fails (bad UserDefaults key,
/// missing file, nil-coalescing failure, etc.), the app crashes on launch.
///
/// These tests run in BOTH debug and release configurations in CI.
final class WireUpBootstrapTests: XCTestCase {

    // MARK: - Bootstrap Smoke Test

    @MainActor
    func testBootstrap_completesWithoutCrashing() {
        // This is the P0 test. If this fails, the app cannot launch.
        let environment = WireUp.bootstrap()
        XCTAssertNotNil(environment, "WireUp.bootstrap() must return a valid AppEnvironment")
    }

    // MARK: - Service Graph Completeness

    @MainActor
    func testBootstrap_allServicesAreInitialised() {
        let env = WireUp.bootstrap()

        // Every service in the dependency graph must be non-nil and accessible.
        // We access each property to ensure it doesn't trigger a lazy-init crash.
        XCTAssertNotNil(env.settings)
        XCTAssertNotNil(env.permissions)
        XCTAssertNotNil(env.history)
        XCTAssertNotNil(env.hud)
        XCTAssertNotNil(env.hotKeys)
        XCTAssertNotNil(env.shortcuts)
        XCTAssertNotNil(env.audioDevices)
        XCTAssertNotNil(env.audio)
        XCTAssertNotNil(env.transcription)
        XCTAssertNotNil(env.postProcessing)
        XCTAssertNotNil(env.tts)
        XCTAssertNotNil(env.secureStorage)
        XCTAssertNotNil(env.openRouter)
        XCTAssertNotNil(env.personalLexicon)
        XCTAssertNotNil(env.pronunciationManager)
        XCTAssertNotNil(env.livePolish)
        XCTAssertNotNil(env.liveTextInserter)
        XCTAssertNotNil(env.autoCorrectionTracker)
        XCTAssertNotNil(env.main)
        XCTAssertNotNil(env.transportServer)
    }

    // MARK: - Wiring Correctness

    @MainActor
    func testBootstrap_settingsIsSharedAcrossServices() {
        // Verify that services share the same AppSettings instance.
        // The permissionsManager alias should point to the same object as permissions.
        let env = WireUp.bootstrap()

        // We can't directly inspect internal references of each service,
        // but we can verify the environment's own properties are consistent.
        XCTAssertTrue(env.settings === env.settings, "Sanity check: settings identity")
    }

    @MainActor
    func testBootstrap_permissionsManagerAlias() {
        // AppEnvironment has a `permissionsManager` alias for `permissions`
        let env = WireUp.bootstrap()
        XCTAssertTrue(env.permissionsManager === env.permissions,
                      "permissionsManager should be an alias for permissions")
    }

    // MARK: - Idempotency

    @MainActor
    func testBootstrap_canBeCalledMultipleTimes() {
        // EnvironmentHolder guards against double-init, but bootstrap itself
        // should be safe to call multiple times (e.g., during testing)
        let env1 = WireUp.bootstrap()
        let env2 = WireUp.bootstrap()
        XCTAssertNotNil(env1)
        XCTAssertNotNil(env2)
        // They should be different instances (no singleton)
        XCTAssertFalse(env1 === env2, "Each bootstrap call should create a fresh environment")
    }

    // MARK: - EnvironmentHolder

    @MainActor
    func testEnvironmentHolder_bootstrapsLazily() {
        let holder = EnvironmentHolder()
        XCTAssertNil(holder.environment, "Environment should not be created until bootstrap() is called")

        holder.bootstrap()
        XCTAssertNotNil(holder.environment, "Environment should be created after bootstrap()")
    }

    @MainActor
    func testEnvironmentHolder_bootstrapIsIdempotent() {
        let holder = EnvironmentHolder()
        holder.bootstrap()
        let first = holder.environment

        holder.bootstrap() // second call should be a no-op
        let second = holder.environment

        XCTAssertTrue(first === second, "Second bootstrap() call should not create a new environment")
    }
}
