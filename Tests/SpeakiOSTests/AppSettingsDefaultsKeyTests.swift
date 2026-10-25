#if os(iOS)
import XCTest

@testable import SpeakiOSLib

@MainActor
final class AppSettingsDefaultsKeyTests: XCTestCase {
    func testSharedNames_LoadSavedValuesAndPersistEditsUnderExistingKeys() throws {
        let suite = "SharedSettingsNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("groq/whisper-large-v3-turbo", forKey: "batchTranscriptionModel")
        defaults.set("anthropic/claude-haiku-4.5", forKey: "postProcessingModel")
        defaults.set("Saved words", forKey: "transcriptionKeywords")
        defaults.set("fr_FR", forKey: "preferredLocale")
        defaults.set(true, forKey: "postProcessingEnabled")
        defaults.set(true, forKey: "handsFreeDictationEnabled")
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertEqual(settings.batchTranscriptionModel, "groq/whisper-large-v3-turbo")
        XCTAssertEqual(settings.postProcessingModel, "anthropic/claude-haiku-4.5")
        XCTAssertEqual(settings.transcriptionKeywords, "Saved words")
        XCTAssertEqual(settings.preferredLocaleIdentifier, "fr_FR")
        XCTAssertTrue(settings.postProcessingEnabled)
        XCTAssertTrue(settings.handsFreeDictationEnabled)

        settings.batchTranscriptionModel = "openai/whisper-1"
        settings.postProcessingModel = "anthropic/claude-sonnet-4.6"
        settings.transcriptionKeywords = "Edited words"
        settings.preferredLocaleIdentifier = "en_GB"
        settings.postProcessingEnabled = false
        settings.handsFreeDictationEnabled = false
        XCTAssertEqual(defaults.string(forKey: "batchTranscriptionModel"), "openai/whisper-1")
        XCTAssertEqual(defaults.string(forKey: "postProcessingModel"), "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(defaults.string(forKey: "transcriptionKeywords"), "Edited words")
        XCTAssertEqual(defaults.string(forKey: "preferredLocale"), "en_GB")
        XCTAssertEqual(defaults.object(forKey: "postProcessingEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "handsFreeDictationEnabled") as? Bool, false)
        let reloaded = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertEqual(reloaded.batchTranscriptionModel, settings.batchTranscriptionModel)
        XCTAssertEqual(reloaded.postProcessingModel, settings.postProcessingModel)
        XCTAssertEqual(reloaded.transcriptionKeywords, settings.transcriptionKeywords)
        XCTAssertEqual(reloaded.preferredLocaleIdentifier, settings.preferredLocaleIdentifier)
        XCTAssertFalse(reloaded.postProcessingEnabled)
        XCTAssertFalse(reloaded.handsFreeDictationEnabled)
    }

    func testSharedNames_KeepIOSDefaultsAndDeviceLocalClipboardPolicy() throws {
        let suite = "SharedSettingsNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(900, forKey: "transcriptClipboardLifetimeSeconds")
        defaults.set(true, forKey: "transcriptClipboardAllowsUniversalClipboard")
        defaults.set(1, forKey: "transcriptClipboardNoticeVersion")
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        // macOS defaults post-processing to true; sharing its name must not adopt its default.
        XCTAssertFalse(settings.postProcessingEnabled)
        XCTAssertFalse(settings.handsFreeDictationEnabled)
        settings.transcriptionKeywords = "Device words"
        let reloaded = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertEqual(reloaded.transcriptClipboardLifetime, .fifteenMinutes)
        XCTAssertTrue(reloaded.transcriptAllowsUniversalClipboard)
        XCTAssertFalse(reloaded.isTranscriptClipboardNoticePending)
        XCTAssertNil(defaults.object(forKey: "assemblyAIKeyterms"), "iOS must not adopt macOS keyword mirrors")
    }

    func testDefaultsKeysPreserveExactPersistedContract() {
        let expected = Set([
            "selectedModel",
            "transcriptionMode",
            "rememberedRemoteTranscriptionMode",
            "batchTranscriptionModel",
            "transcriptionKeywords",
            "liveActivitiesEnabled",
            "visualDensity",
            "autoStartRecording",
            "handsFreeDictationEnabled",
            "preferredLocale",
            "hardwareTriggerDestination",
            "autoStopOnSilenceEnabled",
            "autoStopSilenceSeconds",
            "postProcessingEnabled",
            "postProcessingModel",
            "autoPostProcess",
            "hasLaunchedBefore",
            "transcriptClipboardLifetimeSeconds",
            "transcriptClipboardAllowsUniversalClipboard",
            "transcriptClipboardNoticeVersion"
        ])
        let actual = AppSettings.DefaultsKey.allCases.map(\.rawValue)
        XCTAssertEqual(AppSettings.DefaultsKey.allCases.map(\.storageKey), actual)

        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, expected.count, "Persisted defaults keys must remain unique")
    }
}
#endif
