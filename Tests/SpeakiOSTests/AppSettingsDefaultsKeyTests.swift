#if os(iOS)
import XCTest

@testable import SpeakiOSLib

@MainActor
final class AppSettingsDefaultsKeyTests: XCTestCase {
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

        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, expected.count, "Persisted defaults keys must remain unique")
    }
}
#endif
