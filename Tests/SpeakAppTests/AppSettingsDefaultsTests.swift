// swiftlint:disable file_length
import XCTest
import SpeakHotKeys
import SpeakCore

@testable import SpeakApp

// swiftlint:disable:next type_body_length
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

    // MARK: - Transcription keywords

    /// Issue #849: macOS stored the keyword list under `assemblyAIKeyterms`
    /// while iOS used `transcriptionKeywords`. They are now one value with two
    /// names, so every provider biases on the same words.
    @MainActor
    func testTranscriptionKeywords_defaultToEmptyAndPersistUnderBothNames() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.transcriptionKeywords, "")

        settings.transcriptionKeywords = "JustSpeakToIt, Muse"

        XCTAssertEqual(settings.assemblyAIKeyterms, "JustSpeakToIt, Muse")
        XCTAssertEqual(defaults.string(forKey: "transcriptionKeywords"), "JustSpeakToIt, Muse")
        XCTAssertEqual(defaults.string(forKey: "assemblyAIKeyterms"), "JustSpeakToIt, Muse")
        XCTAssertEqual(AppSettings(defaults: defaults).transcriptionKeywords, "JustSpeakToIt, Muse")
    }

    /// The AssemblyAI keyterms field keeps working and feeds the same list.
    @MainActor
    func testAssemblyAIKeytermsField_stillWritesTheSharedKeywordList() {
        let settings = AppSettings(defaults: defaults)

        settings.assemblyAIKeyterms = "Deepgram, Gladia"

        XCTAssertEqual(settings.transcriptionKeywords, "Deepgram, Gladia")
        XCTAssertEqual(defaults.string(forKey: "transcriptionKeywords"), "Deepgram, Gladia")
    }

    /// An existing macOS install has only the old key; its words survive.
    @MainActor
    func testTranscriptionKeywords_migrateFromTheLegacyKeytermsKey() {
        defaults.set("Muse Voice", forKey: "assemblyAIKeyterms")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.transcriptionKeywords, "Muse Voice")
        XCTAssertEqual(settings.assemblyAIKeyterms, "Muse Voice")
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
    func testCoreDefaults_visualDensityIsNormal() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.visualDensity, .normal)
    }

    @MainActor
    func testVisualDensity_compactPersists() {
        let settings = AppSettings(defaults: defaults)
        settings.visualDensity = .compact

        XCTAssertEqual(defaults.string(forKey: "visualDensity"), "compact")
        XCTAssertEqual(AppSettings(defaults: defaults).visualDensity, .compact)
    }

    @MainActor
    func testLanguagePreference_defaultsToAutomatic() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(
            settings.preferredLocaleIdentifier,
            TranscriptionLanguageCatalog.automaticIdentifier
        )
        XCTAssertNil(settings.preferredModelLanguage)
    }

    @MainActor
    func testLanguagePreference_explicitLocalePersistsAndIsPassedToModels() {
        let settings = AppSettings(defaults: defaults)

        settings.preferredLocaleIdentifier = "fr_FR"

        XCTAssertEqual(defaults.string(forKey: "preferredLocale"), "fr_FR")
        XCTAssertEqual(AppSettings(defaults: defaults).preferredModelLanguage, "fr_FR")
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

    @MainActor
    func testCoreDefaults_showSidebarShortcutHintsIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showSidebarShortcutHints)
    }

    @MainActor
    func testCoreDefaults_shortenErrorDisplayIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.shortenErrorDisplay)
    }

    @MainActor
    func testReconcileAPIKeyIdentifiers_replacesStaleMetadataAndPersistsCanonicalSet() {
        defaults.set(
            ["openrouter.apiKey", "deepgram.apiKey", "assemblyai.apiKey"],
            forKey: "trackedKeyIdentifiers"
        )
        let settings = AppSettings(defaults: defaults)

        settings.reconcileAPIKeyIdentifiers([
            "openai.apiKey",
            "assemblyai.apiKey",
            "openai.apiKey"
        ])

        let expected = ["assemblyai.apiKey", "openai.apiKey"]
        XCTAssertEqual(settings.trackedAPIKeyIdentifiers, expected)
        XCTAssertEqual(defaults.stringArray(forKey: "trackedKeyIdentifiers"), expected)
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
    func testLocalStreamingDefaults_matchHardwareSupport() {
        let settings = AppSettings(defaults: defaults)
        let expected = FluidAudioModelManager.supportsCurrentHardware
          ? FluidAudioParakeetModel.id
          : WhisperKitStreamingModel.id(for: LocalModelManager.shared.availableModels[0])
        XCTAssertEqual(settings.localStreamingModelSource, expected)
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

    @MainActor
    func testStoredHotKey_unsupportedOrdinarySingleKeyFallsBackToFn() throws {
        let unsupported = HotKey.custom(keyCode: 0, modifiers: [])
        defaults.set(try JSONEncoder().encode(unsupported), forKey: "selectedHotKey")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.selectedHotKey, .fnKey)
    }

    func testTextOutputAvailability_appStoreOnlyOffersClipboard() {
        XCTAssertEqual(AppSettings.availableTextOutputMethods(for: .appStore), [.clipboardOnly])
        XCTAssertEqual(
            AppSettings.normalizedTextOutputMethod(.accessibilityOnly, for: .appStore),
            .clipboardOnly
        )
        XCTAssertEqual(
            AppSettings.normalizedTextOutputMethod(.smart, for: .appStore),
            .clipboardOnly
        )
    }

    func testTextOutputAvailability_directKeepsAccessibilityOptions() {
        XCTAssertEqual(
            AppSettings.availableTextOutputMethods(for: .direct),
            AppSettings.TextOutputMethod.allCases
        )
        XCTAssertEqual(
            AppSettings.normalizedTextOutputMethod(.accessibilityOnly, for: .direct),
            .accessibilityOnly
        )
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
        XCTAssertEqual(settings.liveTranscriptionModel, AppleLocalModels.preferredSpeechModelID)
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

    @MainActor
    func testVisibilityDefaults_showStatusBarIconInDockOnlyIsTrue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showStatusBarIconInDockOnly)
    }

    @MainActor
    func testVisibilityDefaults_compactStatusBarIconIsFalse() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.compactStatusBarIcon)
    }

    @MainActor
    func testShouldShowStatusBarIcon_dockOnlyFollowsToggle() {
        let settings = AppSettings(defaults: defaults)
        settings.appVisibility = .dockOnly

        XCTAssertTrue(settings.shouldShowStatusBarIcon)

        settings.showStatusBarIconInDockOnly = false

        XCTAssertFalse(settings.shouldShowStatusBarIcon)
    }

    @MainActor
    func testShouldShowStatusBarIcon_menuBarModesAlwaysShow() {
        let settings = AppSettings(defaults: defaults)
        settings.showStatusBarIconInDockOnly = false

        settings.appVisibility = .menuBarOnly
        XCTAssertTrue(settings.shouldShowStatusBarIcon)

        settings.appVisibility = .dockAndMenuBar
        XCTAssertTrue(settings.shouldShowStatusBarIcon)
    }

    @MainActor
    func testVisibility_alwaysHasAnAccessPoint() {
        let settings = AppSettings(defaults: defaults)
        for visibility in AppSettings.AppVisibility.allCases {
            for statusBarToggle in [true, false] {
                settings.appVisibility = visibility
                settings.showStatusBarIconInDockOnly = statusBarToggle

                let hasDockIcon = visibility.showInDock
                let hasStatusBarIcon = settings.shouldShowStatusBarIcon

                XCTAssertTrue(
                    hasDockIcon || hasStatusBarIcon,
                    "No access point for \(visibility.rawValue) with status bar toggle \(statusBarToggle)"
                )
            }
        }
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
