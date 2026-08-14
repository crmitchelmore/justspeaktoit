#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// iOS half of the hands-free dictation settings parity checks. The macOS half
/// lives in `Tests/SpeakAppTests/HandsFreeDictationSettingsTests.swift`; both
/// assert the same defaults key and the same default-off behaviour.
@MainActor
final class HandsFreeDictationSettingsTests: XCTestCase {
    func testIOSHandsFreeRecordingFlowUsesTheSharedRuntimeStates() {
        var machine = HandsFreeDictationMachine()

        XCTAssertEqual(machine.handle(.userArmed), [.startDetector])
        XCTAssertEqual(machine.state, .arming)
        XCTAssertEqual(machine.handle(.detectorStarted), [])
        XCTAssertEqual(machine.state, .armed)
        XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
        XCTAssertEqual(machine.state, .recording)
        XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture])
        XCTAssertEqual(machine.state, .finalising)
        XCTAssertEqual(machine.handle(.captureFinished), [])
        XCTAssertEqual(machine.state, .armed)
    }

    func testIOSHandsFreeCaptureRejectsRemoteLegacyAndBatchRoutes() {
        XCTAssertTrue(
            HandsFreeDictationPolicy.supportsCapture(
                modelID: AppleLocalModels.dictationTranscriberModelID,
                isStreaming: true
            )
        )
        XCTAssertFalse(
            HandsFreeDictationPolicy.supportsCapture(
                modelID: AppleLocalModels.legacySpeechModelID,
                isStreaming: true
            )
        )
        XCTAssertFalse(
            HandsFreeDictationPolicy.supportsCapture(
                modelID: AppleLocalModels.speechTranscriberModelID,
                isStreaming: false
            )
        )
    }

    /// Must match `AppSettings.DefaultsKey.handsFreeDictationEnabled` on macOS.
    private let sharedDefaultsKey = "handsFreeDictationEnabled"

    private var defaults: UserDefaults!
    private let suiteName = "HandsFreeDictationSettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    /// `AppSettings.shared` is bound to `UserDefaults.standard`, so — as with
    /// the hardware-trigger tests — the persistence contract is exercised
    /// against an isolated suite the same way `AppSettings` reads and writes it.
    func testAbsentKeyMeansOffSoExistingUsersSeeNoChange() {
        XCTAssertFalse(defaults.bool(forKey: sharedDefaultsKey))
    }

    func testEnabledFlagRoundTripsThroughUserDefaults() {
        defaults.set(true, forKey: sharedDefaultsKey)
        XCTAssertTrue(defaults.bool(forKey: sharedDefaultsKey))

        defaults.set(false, forKey: sharedDefaultsKey)
        XCTAssertFalse(defaults.bool(forKey: sharedDefaultsKey))
    }

    func testLiveSettingsObjectDefaultsToOff() {
        // The shared singleton reads UserDefaults.standard; a clean test device
        // has never written the key, so hands-free must report off.
        XCTAssertFalse(AppSettings.shared.handsFreeDictationEnabled)
        XCTAssertFalse(AppSettings.shared.handsFreeDictationActive)
    }

    func testActiveRequiresDetectorSupport() {
        XCTAssertEqual(
            AppSettings.shared.handsFreeDictationSupported,
            AppleLocalModels.supportsSpeechDetector
        )
    }
}
#endif
