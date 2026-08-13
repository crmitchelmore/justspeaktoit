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
    func testHandsFreeDictationIsOffByDefault() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.handsFreeDictationEnabled)
        XCTAssertFalse(settings.handsFreeDictationActive)
    }

    @MainActor
    func testEnablingPersistsUnderTheKeyBothPlatformsShare() {
        let settings = AppSettings(defaults: defaults)

        settings.handsFreeDictationEnabled = true

        XCTAssertEqual(defaults.object(forKey: sharedDefaultsKey) as? Bool, true)
    }

    @MainActor
    func testStoredValueIsRestoredOnRelaunch() {
        defaults.set(true, forKey: sharedDefaultsKey)

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.handsFreeDictationEnabled)
    }

    @MainActor
    func testDefaultsKeyMatchesTheIOSKeyExactly() {
        XCTAssertEqual(AppSettings.DefaultsKey.handsFreeDictationEnabled.rawValue, sharedDefaultsKey)
    }

    /// An enabled setting synced from a newer OS must not change behaviour on a
    /// machine without `SpeechDetector`.
    @MainActor
    func testActiveTracksDetectorSupport() {
        let settings = AppSettings(defaults: defaults)
        settings.handsFreeDictationEnabled = true

        XCTAssertEqual(settings.handsFreeDictationSupported, AppleLocalModels.supportsSpeechDetector)
        XCTAssertEqual(settings.handsFreeDictationActive, AppleLocalModels.supportsSpeechDetector)
    }
}
