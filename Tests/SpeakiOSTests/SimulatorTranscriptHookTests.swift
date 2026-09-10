#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib

/// Cover for the hook the capture XCUITests stand on (issue #998).
///
/// `CaptureFlowUITests` is only meaningful if
/// `JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT` still resolves the way it does today:
/// the launch environment seeds an App Group value at process start, and every
/// later reader — including an App Intent that did not inherit the launchd
/// environment — falls back to that value. If this resolution ever broke, the
/// UI tests would go green while silently exercising the real transcriber, so
/// the hook itself gets a test.
///
/// These run in the simulator, which is where the hook exists at all; the
/// production branch is compiled out of device and release builds.
final class SimulatorTranscriptHookTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SimulatorTranscriptHookTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    #if DEBUG && targetEnvironment(simulator)

    // These construct the state with no environment seed, which is what the
    // defaults fallback is for. The seam matters: `JUSTSPEAKTOIT_SIMULATOR_-`
    // `TRANSCRIPT` takes precedence over the App Group value, a test process
    // cannot unset its own inherited environment, and this bundle is run by the
    // same tooling that sets that variable for the UI bundle. Reading the live
    // process environment here would make the seeded, blank and missing cases
    // pass or fail on how the run was launched.

    func testHook_prefersTheLaunchEnvironmentOverTheSeededAppGroupValue() {
        defaults.set("stale App Group value", forKey: "simulatorValidationTranscript")

        let state = SharedTranscriptionState(
            defaults: defaults, environmentTranscript: "  launch environment wins  "
        )

        XCTAssertEqual(state.simulatorValidationTranscript, "launch environment wins")
    }

    func testHook_resolvesTheSeededAppGroupValueForAProcessThatInheritedNoEnvironment() {
        defaults.set("Regression harness transcript zulu", forKey: "simulatorValidationTranscript")

        let state = SharedTranscriptionState(defaults: defaults)

        XCTAssertEqual(state.simulatorValidationTranscript, "Regression harness transcript zulu")
    }

    func testHook_isInactiveWhenNothingHasBeenSeeded() {
        let state = SharedTranscriptionState(defaults: defaults)

        XCTAssertNil(
            state.simulatorValidationTranscript,
            "An unseeded process must take the real capture path"
        )
    }

    func testHook_treatsABlankSeedAsNoHookRatherThanAnEmptyTranscript() {
        defaults.set("   \n ", forKey: "simulatorValidationTranscript")

        let state = SharedTranscriptionState(defaults: defaults)

        XCTAssertNil(
            state.simulatorValidationTranscript,
            "A blank value must not short-circuit capture with an empty transcript"
        )
    }

    func testHook_trimsSurroundingWhitespaceSoTheUITestCanMatchTheLabelExactly() {
        defaults.set("  spoken words  ", forKey: "simulatorValidationTranscript")

        let state = SharedTranscriptionState(defaults: defaults)

        XCTAssertEqual(state.simulatorValidationTranscript, "spoken words")
    }

    #else

    /// On a device or in Release the hook does not exist to be referenced, so
    /// the whole class is inert. Kept as one test so the bundle reports a
    /// deliberate no-op rather than an empty class.
    func testHook_doesNotExistOutsideSimulatorDebug() throws {
        throw XCTSkip("The simulator transcript hook is compiled out of this configuration")
    }

    #endif
}
#endif
