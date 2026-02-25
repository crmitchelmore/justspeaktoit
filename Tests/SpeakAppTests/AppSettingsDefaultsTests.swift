import XCTest

@testable import SpeakApp

final class AppSettingsDefaultsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    @MainActor
    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Core Settings

    @MainActor
    func testCoreDefaults_textOutputMethodIsClipboardOnly() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.textOutputMethod, .clipboardOnly)
    }

    @MainActor
    func testCoreDefaults_postProcessingEnabledIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.postProcessingEnabled)
    }

    @MainActor
    func testCoreDefaults_appearanceIsSystem() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
    }

    @MainActor
    func testCoreDefaults_accessibilityInsertionModeIsInsertAtCursor() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.accessibilityInsertionMode, .insertAtCursor)
    }

    @MainActor
    func testCoreDefaults_restoreClipboardAfterPasteIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
    }

    // MARK: - Recording Settings

    @MainActor
    func testRecordingDefaults_holdThresholdIs035() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.holdThreshold, 0.35, accuracy: 0.001)
    }

    @MainActor
    func testRecordingDefaults_doubleTapWindowIs04() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.doubleTapWindow, 0.4, accuracy: 0.001)
    }

    @MainActor
    func testRecordingDefaults_recordingSoundsEnabledIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.recordingSoundsEnabled)
    }

    @MainActor
    func testRecordingDefaults_recordingSoundVolumeIs07() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.recordingSoundVolume, 0.7, accuracy: 0.001)
    }

    @MainActor
    func testRecordingDefaults_hotKeyActivationStyleIsHoldAndDoubleTap() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hotKeyActivationStyle, .holdAndDoubleTap)
    }

    @MainActor
    func testRecordingDefaults_selectedHotKeyIsFnKey() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.selectedHotKey, .fnKey)
    }

    // MARK: - Speed Mode Settings

    @MainActor
    func testSpeedModeDefaults_speedModeIsInstant() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.speedMode, .instant)
    }

    @MainActor
    func testSpeedModeDefaults_silenceDetectionEnabledIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.silenceDetectionEnabled)
    }

    // MARK: - Transcription Settings

    @MainActor
    func testTranscriptionDefaults_transcriptionModeIsLiveNative() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.transcriptionMode, .liveNative)
    }

    @MainActor
    func testTranscriptionDefaults_liveTranscriptionModelIsAppleLocal() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.liveTranscriptionModel, "apple/local/SFSpeechRecognizer")
    }

    // MARK: - TTS Settings

    @MainActor
    func testTTSDefaults_autoPlayIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.ttsAutoPlay)
    }

    @MainActor
    func testTTSDefaults_useSSMLIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.ttsUseSSML)
    }

    @MainActor
    func testTTSDefaults_saveToDirectoryIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.ttsSaveToDirectory)
    }

    @MainActor
    func testTTSDefaults_speedIs1() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.ttsSpeed, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testTTSDefaults_qualityIsHigh() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.ttsQuality, .high)
    }

    @MainActor
    func testTTSDefaults_outputFormatIsMp3() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.ttsOutputFormat, .mp3)
    }

    // MARK: - App Visibility Settings

    @MainActor
    func testVisibilityDefaults_appVisibilityIsDockAndMenuBar() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appVisibility, .dockAndMenuBar)
    }

    @MainActor
    func testVisibilityDefaults_runAtLoginIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.runAtLogin)
    }

    // MARK: - HUD Settings

    @MainActor
    func testHUDDefaults_showHUDDuringSessionsIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showHUDDuringSessions)
    }

    @MainActor
    func testHUDDefaults_showLiveTranscriptInHUDIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showLiveTranscriptInHUD)
    }

    @MainActor
    func testHUDDefaults_hudSizePreferenceIsAutoExpand() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hudSizePreference, .autoExpand)
    }

    // MARK: - Float/Double Range Validation

    @MainActor
    func testRangeValidation_holdThresholdIsInValidRange() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertGreaterThanOrEqual(settings.holdThreshold, 0.1)
        XCTAssertLessThanOrEqual(settings.holdThreshold, 1.0)
    }

    @MainActor
    func testRangeValidation_doubleTapWindowIsInValidRange() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertGreaterThanOrEqual(settings.doubleTapWindow, 0.1)
        XCTAssertLessThanOrEqual(settings.doubleTapWindow, 1.0)
    }

    @MainActor
    func testRangeValidation_silenceThresholdIsPositive() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertGreaterThan(settings.silenceThreshold, 0)
    }

    @MainActor
    func testRangeValidation_postProcessingTemperatureIsInValidRange() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertGreaterThanOrEqual(settings.postProcessingTemperature, 0)
        XCTAssertLessThanOrEqual(settings.postProcessingTemperature, 2)
    }
}
