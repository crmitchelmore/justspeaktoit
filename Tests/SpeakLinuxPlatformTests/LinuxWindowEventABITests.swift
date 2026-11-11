import XCTest
import CLinuxSupport
import SpeakDesktopHost

/// Pins the typed window events and pages to the GTK window's constants, so
/// renumbering either side fails here instead of misrouting an event.
final class LinuxWindowEventABITests: XCTestCase {
    private typealias Shared = DesktopNativeWindowEvent
    private typealias Host = DesktopNativeLinuxEvent

    func testSharedEvents_matchNativeConstants() {
        let pairs: [(Shared, Int)] = [
            (.toggleRecording, Int(JSTI_EVENT_TOGGLE_RECORDING)), (.importAudio, Int(JSTI_EVENT_IMPORT)),
            (.copyTranscript, Int(JSTI_EVENT_COPY)), (.saveCredential, Int(JSTI_EVENT_SAVE_KEY)),
            (.selectModel, Int(JSTI_EVENT_SELECT_MODEL)), (.closing, Int(JSTI_EVENT_CLOSING)),
            (.ready, Int(JSTI_EVENT_READY)), (.selectHistory, Int(JSTI_EVENT_SELECT_HISTORY)),
            (.retryHistory, Int(JSTI_EVENT_RETRY_HISTORY)), (.exportHistory, Int(JSTI_EVENT_EXPORT_HISTORY)),
            (.openHistoryAudio, Int(JSTI_EVENT_OPEN_AUDIO)), (.selectMicrophone, Int(JSTI_EVENT_SELECT_MICROPHONE)),
            (.cancel, Int(JSTI_EVENT_CANCEL)), (.searchHistory, Int(JSTI_EVENT_SEARCH_HISTORY)),
            (.transcriptVersion, Int(JSTI_EVENT_TRANSCRIPT_VERSION)),
            (.playbackToggle, Int(JSTI_EVENT_PLAYBACK_TOGGLE)),
            (.playbackStop, Int(JSTI_EVENT_PLAYBACK_STOP)), (.refreshModels, Int(JSTI_EVENT_REFRESH_MODELS)),
            (.shortcutDown, Int(JSTI_EVENT_SHORTCUT_PRESSED)), (.shortcutUp, Int(JSTI_EVENT_SHORTCUT_RELEASED)),
            (.historyFilters, Int(JSTI_EVENT_HISTORY_FILTERS)), (.historyDelete, Int(JSTI_EVENT_HISTORY_DELETE)),
            (.recordingsFolder, Int(JSTI_EVENT_RECORDINGS_FOLDER)), (.audioCleanup, Int(JSTI_EVENT_AUDIO_CLEANUP)),
            (.audioCleanupResponse, Int(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE)),
            (.migrationExport, Int(JSTI_EVENT_MIGRATION_EXPORT)),
            (.migrationInspect, Int(JSTI_EVENT_MIGRATION_INSPECT)),
            (.migrationRestore, Int(JSTI_EVENT_MIGRATION_RESTORE)),
            (.migrationRestoreResponse, Int(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE)),
            (.quickVoice, Int(JSTI_EVENT_QUICK_VOICE)), (.pasteLastHistory, Int(JSTI_EVENT_PASTE_LAST_HISTORY)),
            (.speakClipboard, Int(JSTI_EVENT_SPEAK_CLIPBOARD)), (.speechPause, Int(JSTI_EVENT_SPEECH_PAUSE)),
            (.userAbsent, Int(JSTI_EVENT_USER_ABSENT)), (.historyIssueReport, Int(JSTI_EVENT_HISTORY_ISSUE_REPORT)),
            (.issueReportInclude, Int(JSTI_EVENT_ISSUE_REPORT_INCLUDE)),
            (.issueReportCopy, Int(JSTI_EVENT_ISSUE_REPORT_COPY)),
            (.issueReportSave, Int(JSTI_EVENT_ISSUE_REPORT_SAVE)),
            (.issueReportOpen, Int(JSTI_EVENT_ISSUE_REPORT_OPEN)),
            (.issueReportClose, Int(JSTI_EVENT_ISSUE_REPORT_CLOSE)),
            (.historyLoadMore, Int(JSTI_EVENT_HISTORY_LOAD_MORE)), (.settingsSearch, Int(JSTI_EVENT_SETTINGS_SEARCH)),
            (.settingsSearchOpen, Int(JSTI_EVENT_SETTINGS_SEARCH_OPEN))
        ]
        for (event, native) in pairs { XCTAssertEqual(Int(event.rawValue), native, "\(event)") }
        XCTAssertEqual(Int(Shared.vocabularyAction.rawValue), 70)
    }

    func testLinuxEvents_matchNativeConstants() {
        let pairs: [(Host, Int)] = [
            (.textOutput, Int(JSTI_EVENT_TEXT_OUTPUT)), (.commandToggle, Int(JSTI_EVENT_COMMAND_TOGGLE)),
            (.shortcutStyle, Int(JSTI_EVENT_SHORTCUT_STYLE)), (.postProcessing, Int(JSTI_EVENT_POST_PROCESSING)),
            (.azureResource, Int(JSTI_EVENT_AZURE_RESOURCE)), (.readAloud, Int(JSTI_EVENT_READ_ALOUD)),
            (.voiceOutput, Int(JSTI_EVENT_VOICE_OUTPUT)), (.appearance, Int(JSTI_EVENT_APPEARANCE)),
            (.loginItem, Int(JSTI_EVENT_LOGIN_ITEM)), (.automation, Int(JSTI_EVENT_AUTOMATION)),
            (.localModelDownload, Int(JSTI_EVENT_LOCAL_MODEL_DOWNLOAD)),
            (.localModelCancel, Int(JSTI_EVENT_LOCAL_MODEL_CANCEL)),
            (.localModelRemove, Int(JSTI_EVENT_LOCAL_MODEL_REMOVE)), (.localModelGPU, Int(JSTI_EVENT_LOCAL_MODEL_GPU)),
            (.localModelImport, Int(JSTI_EVENT_LOCAL_MODEL_IMPORT)),
            (.localModelImportCancel, Int(JSTI_EVENT_LOCAL_MODEL_IMPORT_CANCEL)),
            (.cloudSyncApply, Int(JSTI_EVENT_CLOUD_SYNC_APPLY)),
            (.cloudSyncSignIn, Int(JSTI_EVENT_CLOUD_SYNC_SIGN_IN)),
            (.cloudSyncSignOut, Int(JSTI_EVENT_CLOUD_SYNC_SIGN_OUT)), (.cloudSyncNow, Int(JSTI_EVENT_CLOUD_SYNC_NOW)),
            (.recordingsLocation, Int(JSTI_EVENT_RECORDINGS_LOCATION)),
            (.actionShortcutEdit, Int(JSTI_EVENT_ACTION_SHORTCUT_EDIT)), (.apiKeys, Int(JSTI_EVENT_API_KEYS)),
            (.permissions, Int(JSTI_EVENT_PERMISSIONS)), (.speakSelectedText, Int(JSTI_EVENT_SPEAK_SELECTED_TEXT)),
            (.profiles, Int(JSTI_EVENT_PROFILES))
        ]
        for (event, native) in pairs { XCTAssertEqual(Int(event.rawValue), native, "\(event)") }
    }

    func testPages_matchNativeConstants() {
        XCTAssertEqual(DesktopNativePage.allCases.count, Int(JSTI_PAGE_COUNT))
        XCTAssertEqual(Int(DesktopNativePage.about.rawValue), Int(JSTI_PAGE_ABOUT))
        XCTAssertEqual(Int(DesktopNativePage.corrections.rawValue), Int(JSTI_PAGE_CORRECTIONS))
        XCTAssertEqual(Int(DesktopNativePage.cloudSync.rawValue), Int(JSTI_PAGE_CLOUD_SYNC))
    }
}
