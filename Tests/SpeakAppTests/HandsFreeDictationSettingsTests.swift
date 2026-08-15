import XCTest
import SpeakCore

@testable import SpeakApp

/// Hands-free dictation must stay off unless the user turns it on, and must
/// persist under the same defaults key iOS uses so the two platforms agree.
final class HandsFreeDictationSettingsTests: XCTestCase {

    /// The single source of truth both platforms write. macOS writes it via
    /// `DefaultsKey.handsFreeDictationEnabled`; iOS writes the same literal.
    private let sharedDefaultsKey = "handsFreeDictationEnabled"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.handsfree.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testHandsFreeDictation_IsOffByDefault() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.handsFreeDictationEnabled)
        XCTAssertFalse(settings.handsFreeDictationActive)
    }

    @MainActor
    func testEnablingHandsFree_PersistsUnderTheSharedKey() {
        let settings = AppSettings(defaults: defaults)

        settings.handsFreeDictationEnabled = true

        XCTAssertEqual(defaults.object(forKey: sharedDefaultsKey) as? Bool, true)
    }

    @MainActor
    func testStoredHandsFreeValue_IsRestoredOnRelaunch() {
        defaults.set(true, forKey: sharedDefaultsKey)

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.handsFreeDictationEnabled)
    }

    @MainActor
    func testDefaultsKey_MatchesTheIOSKeyExactly() {
        XCTAssertEqual(AppSettings.DefaultsKey.handsFreeDictationEnabled.rawValue, sharedDefaultsKey)
    }

    /// An enabled setting synced from a newer OS must not change behaviour on a
    /// machine without `SpeechDetector`.
    @MainActor
    func testActiveState_TracksDetectorAndCaptureSupport() {
        let settings = AppSettings(defaults: defaults)
        settings.handsFreeDictationEnabled = true
        settings.transcriptionMode = .liveNative
        settings.liveTranscriptionModel = AppleLocalModels.dictationTranscriberModelID

        XCTAssertEqual(settings.handsFreeDictationSupported, AppleLocalModels.supportsSpeechDetector)
        XCTAssertEqual(settings.handsFreeDictationActive, AppleLocalModels.supportsSpeechDetector)

        settings.liveTranscriptionModel = AppleLocalModels.legacySpeechModelID

        XCTAssertFalse(settings.handsFreeDictationActive)
    }

    /// Level-based auto-stop asks the session who owns its silence, so the
    /// hands-free trigger must survive on the session that hands-free started.
    func testSessionKeepsItsTrigger_SoSilenceHasOneOwner() {
        let handsFree = ActiveSession(
            gesture: .uiButton,
            hotKeyDescription: "Fn",
            trigger: .handsFree
        )
        let manual = ActiveSession(gesture: .uiButton, hotKeyDescription: "Fn")

        XCTAssertEqual(handsFree.trigger, .handsFree)
        XCTAssertNotEqual(manual.trigger, .handsFree)
    }
}
