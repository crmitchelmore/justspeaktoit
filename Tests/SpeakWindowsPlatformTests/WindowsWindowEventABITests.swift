import XCTest
import CWindowsSupport
import SpeakDesktopHost

/// Pins the typed window events and pages to the native window's constants,
/// so renumbering either side fails here instead of misrouting an event.
final class WindowsWindowEventABITests: XCTestCase {
    private typealias Shared = DesktopNativeWindowEvent
    private typealias Host = DesktopNativeWindowsEvent

    func testSharedEvents_matchNativeConstants() {
        let pairs: [(Shared, JSTIWindowEvent)] = [
            (.toggleRecording, JSTI_EVENT_TOGGLE_RECORDING), (.importAudio, JSTI_EVENT_IMPORT_AUDIO),
            (.copyTranscript, JSTI_EVENT_COPY_TRANSCRIPT), (.saveCredential, JSTI_EVENT_SAVE_CREDENTIAL),
            (.selectModel, JSTI_EVENT_MODEL_CHANGED), (.closing, JSTI_EVENT_CLOSING), (.ready, JSTI_EVENT_READY),
            (.selectHistory, JSTI_EVENT_HISTORY_SELECTED), (.retryHistory, JSTI_EVENT_HISTORY_RETRY),
            (.exportHistory, JSTI_EVENT_HISTORY_EXPORT), (.openHistoryAudio, JSTI_EVENT_HISTORY_OPEN_AUDIO),
            (.selectMicrophone, JSTI_EVENT_MICROPHONE_CHANGED), (.cancel, JSTI_EVENT_CANCEL_TRANSCRIPTION),
            (.searchHistory, JSTI_EVENT_HISTORY_SEARCH), (.transcriptVersion, JSTI_EVENT_TRANSCRIPT_VARIANT),
            (.playbackToggle, JSTI_EVENT_HISTORY_PLAY_PAUSE), (.playbackStop, JSTI_EVENT_HISTORY_STOP),
            (.refreshModels, JSTI_EVENT_REFRESH_MODELS), (.shortcutDown, JSTI_EVENT_HOTKEY_DOWN),
            (.shortcutUp, JSTI_EVENT_HOTKEY_UP), (.historyFilters, JSTI_EVENT_HISTORY_FILTERS),
            (.historyDelete, JSTI_EVENT_HISTORY_DELETE), (.recordingsFolder, JSTI_EVENT_RECORDINGS_FOLDER),
            (.audioCleanup, JSTI_EVENT_AUDIO_CLEANUP), (.audioCleanupResponse, JSTI_EVENT_AUDIO_CLEANUP_RESPONSE),
            (.migrationExport, JSTI_EVENT_MIGRATION_EXPORT), (.migrationInspect, JSTI_EVENT_MIGRATION_INSPECT),
            (.migrationRestore, JSTI_EVENT_MIGRATION_RESTORE),
            (.migrationRestoreResponse, JSTI_EVENT_MIGRATION_RESTORE_RESPONSE),
            (.quickVoice, JSTI_EVENT_QUICK_VOICE), (.pasteLastHistory, JSTI_EVENT_PASTE_LAST_HISTORY),
            (.speakClipboard, JSTI_EVENT_SPEAK_CLIPBOARD), (.speechPause, JSTI_EVENT_SPEECH_PAUSE),
            (.userAbsent, JSTI_EVENT_USER_ABSENT), (.historyIssueReport, JSTI_EVENT_HISTORY_ISSUE_REPORT),
            (.issueReportInclude, JSTI_EVENT_ISSUE_REPORT_INCLUDE), (.issueReportCopy, JSTI_EVENT_ISSUE_REPORT_COPY),
            (.issueReportSave, JSTI_EVENT_ISSUE_REPORT_SAVE), (.issueReportOpen, JSTI_EVENT_ISSUE_REPORT_OPEN),
            (.issueReportClose, JSTI_EVENT_ISSUE_REPORT_CLOSE), (.historyLoadMore, JSTI_EVENT_HISTORY_LOAD_MORE),
            (.settingsSearch, JSTI_EVENT_SETTINGS_SEARCH), (.settingsSearchOpen, JSTI_EVENT_SETTINGS_SEARCH_OPEN),
            (.systemResourceRelease, JSTI_EVENT_SYSTEM_RESOURCE_RELEASE),
            (.systemResourcesReleaseAll, JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL),
            (.rawConfiguration, JSTI_EVENT_RAW_CONFIGURATION)
        ]
        for (event, native) in pairs {
            XCTAssertEqual(Int64(event.rawValue), Int64(native.rawValue), "\(event)")
        }
    }

    func testWindowsEvents_matchNativeConstants() {
        let pairs: [(Host, JSTIWindowEvent)] = [
            (.error, JSTI_EVENT_ERROR), (.hotKeyDeadline, JSTI_EVENT_HOTKEY_DEADLINE),
            (.readAloud, JSTI_EVENT_HISTORY_READ_ALOUD), (.automation, JSTI_EVENT_AUTOMATION_TOGGLED),
            (.appearance, JSTI_EVENT_APPEARANCE), (.loginItem, JSTI_EVENT_LOGIN_ITEM),
            (.speakSelectedText, JSTI_EVENT_SPEAK_SELECTED_TEXT), (.voiceEdit, JSTI_EVENT_VOICE_EDIT)
        ]
        for (event, native) in pairs {
            XCTAssertEqual(Int64(event.rawValue), Int64(native.rawValue), "\(event)")
        }
        // The window reports these by number; there is no named constant.
        XCTAssertEqual(Host.profiles.rawValue, 17)
        XCTAssertEqual(Shared.vocabularyAction.rawValue, 70)
    }

    func testPages_matchNativeConstants() {
        XCTAssertEqual(DesktopNativePage.allCases.count, Int(JSTI_PAGE_COUNT))
        XCTAssertEqual(Int(DesktopNativePage.about.rawValue), Int(JSTI_PAGE_ABOUT))
        XCTAssertEqual(Int(DesktopNativePage.corrections.rawValue), Int(JSTI_PAGE_CORRECTIONS))
        XCTAssertEqual(Int(DesktopNativePage.cloudSync.rawValue), Int(JSTI_PAGE_CLOUD_SYNC))
    }
}
