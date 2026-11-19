// Main window check stages: History rows, actions, playback, search and
// filtered snapshots, then recording locks and Escape cancellation.
#include "WindowsWindowSelfTestInternal.hpp"
#include "../CWindowsSupport/WindowsWindowHistoryPage.hpp"
#include "../CWindowsSupport/WindowsWindowModelsPage.hpp"

namespace jsti_window {

// History rows, actions, playback, search and filtered snapshots.
bool windowHistoryChecks(WindowCheck &check) {
    [[maybe_unused]] HWND window = check.window;
    [[maybe_unused]] WindowCheckEvent &observed = check.observed;
    [[maybe_unused]] std::string &failure = check.failure;
    [[maybe_unused]] const std::function<bool()> &checkBounds = check.checkBounds;
    const JSTIHistoryRow first[] = {{"one", "First recording", "Completed"}, {"two", "Second recording", "Failed"}};
    if (jsti_window_set_history_management(nullptr) != -1 ||
        jsti_window_set_history_management("\xff") != -1) {
        failure = "Invalid History management input was accepted."; return false;
    }
    if (jsti_window_set_history_management("one\ntwo") != 0) {
        failure = "Complete History management snapshot was refused."; return false;
    }
    if (jsti_window_set_history(first, 2, "two") != 0) { failure = "Initial history update failed."; return false; }
    applyUpdate(window);
    if (SendDlgItemMessageW(window, historyID, LB_GETCOUNT, 0, 0) != 2 || selectedHistory(window) != "two") {
        failure = "History rows or explicit selection were not rendered."; return false;
    }
    if (!IsWindowEnabled(GetDlgItem(window, historyDeleteID)) ||
        !IsWindowEnabled(GetDlgItem(window, historyClearID)) || historyManagementIDs() != "one\ntwo") {
        failure = "History deletion controls did not use the retained snapshot."; return false;
    }
    const JSTIHistoryRow reordered[] = {first[1], first[0]};
    if (jsti_window_set_history(reordered, 2, nullptr) != 0) { failure = "History replacement failed."; return false; }
    applyUpdate(window);
    if (selectedHistory(window) != "two" || SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0) != 0) {
        failure = "History selection did not survive a reordered snapshot."; return false;
    }
    const JSTIHistoryRow duplicates[] = {first[0], first[0]};
    if (jsti_window_set_history(duplicates, 2, nullptr) != -1) {
        failure = "Duplicate history IDs were not rejected."; return false;
    }
    SendDlgItemMessageW(window, historyID, LB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(historyID, LBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "one") {
        failure = "History selection did not report the selected record ID."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 0, "First original", "Saved first");
    applyUpdate(window);
    const int controls[] = {retryID, exportID, openAudioID, copyID};
    const int events[] = {JSTI_EVENT_HISTORY_RETRY, JSTI_EVENT_HISTORY_EXPORT,
                          JSTI_EVENT_HISTORY_OPEN_AUDIO, JSTI_EVENT_COPY_TRANSCRIPT};
    for (size_t i = 0; i < 4; ++i) {
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(controls[i], BN_CLICKED), 0);
        if (observed.event != events[i] || observed.id != "one" || observed.model != 1) {
            failure = "A history action did not report its selected record ID."; return false;
        }
    }
    // Playback controls: idle for a selected record until the host reports,
    // record-bound and latest-only, with Stop available only while active.
    auto playbackLabel = [&]() {
        wchar_t label[32] = {};
        GetDlgItemTextW(window, playPauseID, label, 32);
        return std::wstring(label);
    };
    auto playbackTime = [&]() {
        wchar_t time[64] = {};
        GetDlgItemTextW(window, playbackTimeID, time, 64);
        return std::wstring(time);
    };
    if (!IsWindowEnabled(GetDlgItem(window, playPauseID)) || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) ||
        playbackLabel() != L"Play" || playbackTime() != playbackIdleText) {
        failure = "Playback controls were not idle for a selected record."; return false;
    }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(playPauseID, BN_CLICKED), 0);
    if (observed.event != JSTI_EVENT_HISTORY_PLAY_PAUSE || observed.id != "one" || observed.model != 1) {
        failure = "Play did not report the selected record."; return false;
    }
    jsti_window_action_command(window, JSTI_ACTION_RUN_PLAY_PAUSE, nullptr);
    if (observed.event != JSTI_EVENT_SPEECH_PAUSE) {
        failure = "The speech shortcut fell back to History playback."; return false;
    }
    observed.event = -500;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(stopPlaybackID, BN_CLICKED), 0);
    if (observed.event != -500) { failure = "A disabled Stop emitted a playback event."; return false; }
    if (jsti_window_set_playback("one", 4, "bad") != -1 || jsti_window_set_playback("\xff", 2, "bad") != -1 ||
        jsti_window_set_playback("two", playbackPlaying, "00:00.10 / 00:01.90") != 0) {
        failure = "Playback report validation failed."; return false;
    }
    applyUpdate(window);
    if (historyView().displayedPlayback != playbackIdle || playbackLabel() != L"Play" ||
        IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || playbackTime() != playbackIdleText) {
        failure = "A playback report for another record changed the selected row's controls."; return false;
    }
    if (jsti_window_set_playback("one", playbackPreparing, "00:00.00 / 00:02.00") != 0 ||
        jsti_window_set_playback("one", playbackPlaying, "00:00.10 / 00:01.90") != 0) {
        failure = "Playback reports for the selected record were rejected."; return false;
    }
    applyUpdate(window);
    if (historyView().displayedPlayback != playbackPlaying || playbackLabel() != L"Pause" ||
        !IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || !IsWindowEnabled(GetDlgItem(window, playPauseID)) ||
        playbackTime() != L"00:00.10 / 00:01.90") {
        failure = "A playing report did not show Pause, Stop and the latest time."; return false;
    }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(stopPlaybackID, BN_CLICKED), 0);
    if (observed.event != JSTI_EVENT_HISTORY_STOP || observed.id != "one") {
        failure = "Stop did not report the selected record."; return false;
    }
    // Recording locks Play for an idle record but keeps an active playback
    // pausable and stoppable, and never touches status or transcript.
    jsti_window_update("Playback status sentinel", "Playback transcript sentinel", 1);
    applyUpdate(window);
    const bool activeWhileRecording = IsWindowEnabled(GetDlgItem(window, playPauseID)) &&
        IsWindowEnabled(GetDlgItem(window, stopPlaybackID));
    jsti_window_set_playback("one", playbackPaused, "00:00.50 / 00:01.50");
    applyUpdate(window);
    const bool pausedWhileRecording = historyView().displayedPlayback == playbackPaused && playbackLabel() == L"Play" &&
        IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) && playbackTime() == L"00:00.50 / 00:01.50";
    jsti_window_set_playback("one", playbackIdle, "00:00.00 / 00:02.00");
    applyUpdate(window);
    const bool idleWhileRecording = !IsWindowEnabled(GetDlgItem(window, playPauseID)) &&
        !IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) && playbackTime() == L"00:00.00 / 00:02.00";
    wchar_t playbackStatus[64] = {}, playbackTranscript[64] = {};
    GetDlgItemTextW(window, statusID, playbackStatus, 64);
    GetDlgItemTextW(window, transcriptID, playbackTranscript, 64);
    jsti_window_update(nullptr, nullptr, 0);
    applyUpdate(window);
    if (!activeWhileRecording || !pausedWhileRecording || !idleWhileRecording ||
        !IsWindowEnabled(GetDlgItem(window, playPauseID)) || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) ||
        std::wstring(playbackStatus) != L"Playback status sentinel" ||
        std::wstring(playbackTranscript) != L"Playback transcript sentinel") {
        failure = "Recording lockout or status preservation failed for playback controls."; return false;
    }
    // Explicitly re-selecting the same record (a History refresh after Retry)
    // keeps its playback report: a paused run is not re-sent while unchanged.
    jsti_window_set_playback("one", playbackPaused, "00:00.50 / 00:01.50");
    applyUpdate(window);
    if (jsti_window_set_history(reordered, 2, "one") != 0) {
        failure = "Explicit same-record history update failed."; return false;
    }
    applyUpdate(window);
    if (selectedHistory(window) != "one" || historyView().displayedPlayback != playbackPaused || playbackLabel() != L"Play" ||
        !IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || playbackTime() != L"00:00.50 / 00:01.50") {
        failure = "Explicitly re-selecting a record discarded its active playback state."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 0, "First original", "Saved first");
    applyUpdate(window);
    // Selecting another row resets the display; a late report for the
    // previous record is ignored, and an empty record resets explicitly.
    jsti_window_set_playback("one", playbackPlaying, "00:01.00 / 00:01.00");
    applyUpdate(window);
    SendDlgItemMessageW(window, historyID, LB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(historyID, LBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "two" || historyView().displayedPlayback != playbackIdle ||
        playbackLabel() != L"Play" || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || playbackTime() != playbackIdleText) {
        failure = "Selecting another record did not reset the playback display."; return false;
    }
    jsti_window_set_playback("one", playbackPlaying, "00:01.10 / 00:00.90");
    applyUpdate(window);
    if (historyView().displayedPlayback != playbackIdle || IsWindowEnabled(GetDlgItem(window, stopPlaybackID))) {
        failure = "A stale playback report was applied to a different record."; return false;
    }
    jsti_window_set_playback("two", playbackPlaying, "00:00.20 / 00:00.80");
    applyUpdate(window);
    jsti_window_set_playback("", playbackPlaying, nullptr);
    applyUpdate(window);
    if (historyView().displayedPlayback != playbackIdle || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) ||
        playbackTime() != playbackIdleText || !checkBounds()) {
        if (failure.empty()) failure = "An empty playback report did not reset the controls.";
        return false;
    }
    SendDlgItemMessageW(window, historyID, LB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(historyID, LBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "one") {
        failure = "History selection could not return to the first record after playback checks."; return false;
    }
    // Search: every edit reports the exact current query (UTF-8), and the
    // clear affordance becomes available only while a query is present.
    if (IsWindowEnabled(GetDlgItem(window, clearSearchID)) || jsti_window_transcript_variant() != -1) {
        failure = "Search or transcript version controls were active before any query or version."; return false;
    }
    SetDlgItemTextW(window, searchID, L"Caf\x00e9");
    if (observed.event != JSTI_EVENT_HISTORY_SEARCH || observed.id != "Caf\xc3\xa9" || observed.model != 1 ||
        !IsWindowEnabled(GetDlgItem(window, clearSearchID))) {
        failure = "Typing a search did not report the exact query text."; return false;
    }
    // The host answers with a filtered snapshot. When the selected record is
    // absent, the stale selection, detail and record-bound actions clear.
    const JSTIHistoryRow filtered[] = {first[1]};
    if (jsti_window_set_history(filtered, 1, "") != 0) { failure = "Filtered history update failed."; return false; }
    applyUpdate(window);
    observed.id = "sentinel";
    const int previousSearchEvent = observed.event;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(retryID, BN_CLICKED), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(exportID, BN_CLICKED), 0);
    if (SendDlgItemMessageW(window, historyID, LB_GETCOUNT, 0, 0) != 1 || !selectedHistory(window).empty() ||
        IsWindowEnabled(GetDlgItem(window, retryID)) || IsWindowEnabled(GetDlgItem(window, exportID)) ||
        IsWindowEnabled(GetDlgItem(window, openAudioID)) || IsWindowEnabled(GetDlgItem(window, variantID)) ||
        jsti_window_transcript_variant() != -1 || observed.event != previousSearchEvent || observed.id != "sentinel") {
        failure = "A filtered history did not clear the hidden selection and its actions."; return false;
    }
    if (jsti_window_set_history(nullptr, 0, "") != 0) { failure = "Empty search result update failed."; return false; }
    applyUpdate(window);
    wchar_t detail[64] = {};
    GetDlgItemTextW(window, historyDetailID, detail, 64);
    if (std::wstring(detail) != L"No saved recordings match this search or filter.") {
        failure = "An empty search result did not explain the missing rows."; return false;
    }
    // A fresh launch sends its empty History and Ready status together; the
    // status must not be replaced by the no-selection placeholder.
    if (jsti_window_set_history(nullptr, 0, "") != 0 || jsti_window_update("Ready sentinel", "", 0) != 0) {
        failure = "Empty history with status update failed."; return false;
    }
    applyUpdate(window);
    wchar_t readyStatus[64] = {};
    GetDlgItemTextW(window, statusID, readyStatus, 64);
    if (std::wstring(readyStatus) != L"Ready sentinel") {
        failure = "A status sent with an empty History refresh was replaced by the placeholder."; return false;
    }
    // Clearing empties the box, reports a blank query and lets the host
    // restore the full rows with a consistent selection.
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(clearSearchID, BN_CLICKED), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SEARCH || !observed.id.empty() || searching(window) ||
        IsWindowEnabled(GetDlgItem(window, clearSearchID))) {
        failure = "Clearing the search did not report a blank query."; return false;
    }
    if (jsti_window_set_history(reordered, 2, "one") != 0) { failure = "History restore after search failed."; return false; }
    applyUpdate(window);
    GetDlgItemTextW(window, historyDetailID, detail, 64);
    if (selectedHistory(window) != "one" || !IsWindowEnabled(GetDlgItem(window, retryID)) ||
        std::wstring(detail) != L"Completed" || jsti_window_transcript_variant() != -1) {
        failure = "Restoring rows after clearing the search did not restore the selection."; return false;
    }
    // Transcript version: the host reports both versions; processed is the
    // default, and a user choice is echoed for the selected record.
    if (jsti_window_set_transcript_variant("one", 2, 0) != -1 || jsti_window_set_history_presentation("one", 0, 1, "Processed one", "Saved processed") != 0) {
        failure = "Transcript version configuration validation failed."; return false;
    }
    applyUpdate(window);
    if (!IsWindowEnabled(GetDlgItem(window, variantID)) || jsti_window_transcript_variant() != 0 ||
        SendDlgItemMessageW(window, variantID, CB_GETCURSEL, 0, 0) != 0) {
        failure = "The transcript version did not default to the processed text."; return false;
    }
    SendDlgItemMessageW(window, variantID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(variantID, CBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_TRANSCRIPT_VARIANT || observed.id != "one" || observed.model != 1 ||
        jsti_window_transcript_variant() != 1) {
        failure = "Choosing the original transcript did not report the selected record."; return false;
    }
    auto transcriptText = [&]() {
        wchar_t text[128]{};
        GetDlgItemTextW(window, transcriptID, text, 128);
        return std::wstring(text);
    };
    auto statusText = [&]() {
        wchar_t text[128]{};
        GetDlgItemTextW(window, statusID, text, 128);
        return std::wstring(text);
    };
    auto awaitingPresentation = [&]() {
        size_t required = 99;
        return transcriptText().empty() && !IsWindowEnabled(GetDlgItem(window, copyID)) &&
            !IsWindowEnabled(GetDlgItem(window, exportID)) &&
            jsti_window_transcript_snapshot(nullptr, 0, &required) == -1 && required == 0;
    };
    const int beforePendingActions = observed.event;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(copyID, BN_CLICKED), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(exportID, BN_CLICKED), 0);
    if (!awaitingPresentation() || observed.event != beforePendingActions) {
        failure = "Changing transcript version retained old text or allowed premature Copy/Export."; return false;
    }
    jsti_window_set_history_presentation("one", 0, 1, "Stale processed one", "Stale");
    applyUpdate(window);
    if (!awaitingPresentation() || jsti_window_transcript_variant() != 1 || statusText() == L"Stale") {
        failure = "A delayed processed render replaced the requested original version."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 1, "Original one", "Saved original");
    applyUpdate(window);
    if (transcriptText() != L"Original one" || !IsWindowEnabled(GetDlgItem(window, copyID)) ||
        !IsWindowEnabled(GetDlgItem(window, exportID))) {
        failure = "The matching original render did not enable its transcript actions."; return false;
    }
    // Capture before an actor hop/modal dialog. Replacing the same saved
    // record must not change this owned action snapshot; too-small buffers
    // report required size instead of truncating or falling back to storage.
    size_t required = 0;
    if (jsti_window_transcript_snapshot(nullptr, 0, &required) != 2 || required != 13) {
        failure = "Displayed transcript snapshot sizing failed."; return false;
    }
    std::vector<char> snapshot(required, 0);
    char shortBuffer = 'x';
    if (jsti_window_transcript_snapshot(&shortBuffer, 1, &required) != 2 || shortBuffer != 'x' ||
        jsti_window_transcript_snapshot(snapshot.data(), snapshot.size(), &required) != 0) {
        failure = "Displayed transcript snapshot was truncated or unavailable."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 1, "Replacement one", "Retried");
    applyUpdate(window);
    if (std::string(snapshot.data()) != "Original one" || transcriptText() != L"Replacement one") {
        failure = "A same-record replacement changed the captured action text."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 1, "", "Valid empty result");
    applyUpdate(window);
    if (jsti_window_transcript_snapshot(snapshot.data(), snapshot.size(), &required) != 0 || required != 1 ||
        snapshot.front() != 0) {
        failure = "A valid empty transcript was confused with an unavailable snapshot."; return false;
    }
    jsti_window_set_history_presentation("one", 1, 1, "Original one", "Saved original");
    applyUpdate(window);
    // Copy and Export identify the record and the displayed version together.
    const int variantActions[] = {copyID, exportID};
    const int variantEvents[] = {JSTI_EVENT_COPY_TRANSCRIPT, JSTI_EVENT_HISTORY_EXPORT};
    for (size_t i = 0; i < 2; ++i) {
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(variantActions[i], BN_CLICKED), 0);
        if (observed.event != variantEvents[i] || observed.id != "one" || jsti_window_transcript_variant() != 1) {
            failure = "A transcript action lost the displayed version or record identity."; return false;
        }
    }
    // A record with only an original transcript reports it without a choice.
    if (jsti_window_set_transcript_variant("one", 1, 0) != 0) { failure = "Original-only version update failed."; return false; }
    applyUpdate(window);
    if (IsWindowEnabled(GetDlgItem(window, variantID)) || jsti_window_transcript_variant() != 1) {
        failure = "An original-only record offered a processed version."; return false;
    }
    // Queue an older explicit row selection, then change selection before
    // the UI applies it. Neither that row snapshot nor a stale text update
    // may override the more recent native user event.
    jsti_window_set_history(reordered, 2, "one");
    // Selecting another record forgets the previous record's version until
    // the host reports the new one; a late report for the old record is ignored.
    SendDlgItemMessageW(window, historyID, LB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(historyID, LBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "two" ||
        jsti_window_transcript_variant() != -1 || IsWindowEnabled(GetDlgItem(window, variantID))) {
        failure = "A new selection kept the previous record's transcript version."; return false;
    }
    if (!awaitingPresentation()) {
        failure = "Selecting another record retained old text or enabled transcript actions."; return false;
    }
    jsti_window_set_transcript_variant("one", 1, 1);
    jsti_window_set_history_presentation("one", 1, 1, "Delayed original one", "Stale");
    jsti_window_update(nullptr, "Legacy untagged text", -1);
    applyUpdate(window);
    if (selectedHistory(window) != "two" || !awaitingPresentation() ||
        jsti_window_transcript_variant() != -1 || IsWindowEnabled(GetDlgItem(window, variantID)) ||
        statusText() == L"Stale") {
        failure = "A delayed row, text or version update replaced the newer native selection."; return false;
    }
    jsti_window_set_history_presentation("two", 0, 1, "Processed two", "Saved two");
    applyUpdate(window);
    if (transcriptText() != L"Processed two" || statusText() != L"Saved two" ||
        !IsWindowEnabled(GetDlgItem(window, copyID)) ||
        !IsWindowEnabled(GetDlgItem(window, exportID))) {
        failure = "The matching selected record was not rendered atomically."; return false;
    }
    // Search/list refreshes preserve the actual native selection even if
    // the actor's prior selection has not caught up. A hidden row clears.
    jsti_window_set_history(first, 2, nullptr);
    applyUpdate(window);
    if (selectedHistory(window) != "two" || transcriptText() != L"Processed two") {
        failure = "A reordered search snapshot replaced the visible transcript selection."; return false;
    }
    jsti_window_set_history(first, 1, nullptr);
    jsti_window_set_history_presentation("two", 0, 1, "Late hidden two", "Stale");
    applyUpdate(window);
    if (!selectedHistory(window).empty() || !transcriptText().empty() ||
        IsWindowEnabled(GetDlgItem(window, exportID))) {
        failure = "A hidden record's delayed render survived a filtered row snapshot."; return false;
    }
    jsti_window_set_history(reordered, 2, "two");
    jsti_window_set_history_presentation("two", 0, 1, "Processed two", "Saved two");
    applyUpdate(window);
    return true;
}

// Recording locks History and settings; Escape cancels only what it owns.
bool windowRecordingLockChecks(WindowCheck &check) {
    [[maybe_unused]] HWND window = check.window;
    [[maybe_unused]] WindowCheckEvent &observed = check.observed;
    [[maybe_unused]] std::string &failure = check.failure;
    [[maybe_unused]] const std::function<bool()> &checkBounds = check.checkBounds;
    jsti_window_update(nullptr, nullptr, 1);
    applyUpdate(window);
    const bool searchLockedWhileRecording = !IsWindowEnabled(GetDlgItem(window, searchID)) &&
        !IsWindowEnabled(GetDlgItem(window, clearSearchID)) && !IsWindowEnabled(GetDlgItem(window, variantID)) &&
        !IsWindowEnabled(GetDlgItem(window, copyID));
    jsti_window_update(nullptr, nullptr, 0);
    applyUpdate(window);
    if (!searchLockedWhileRecording || !IsWindowEnabled(GetDlgItem(window, searchID)) ||
        !IsWindowEnabled(GetDlgItem(window, variantID)) || jsti_window_transcript_variant() != 0) {
        failure = "Recording did not lock search and transcript version controls."; return false;
    }
    SendDlgItemMessageW(window, historyID, LB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(historyID, LBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "one") {
        failure = "History selection could not return to the first record."; return false;
    }
    jsti_window_update(nullptr, nullptr, 2);
    applyUpdate(window);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
    const bool cancellation = observed.event == JSTI_EVENT_CANCEL_TRANSCRIPTION &&
        IsWindowEnabled(GetDlgItem(window, recordID)) && !IsWindowEnabled(GetDlgItem(window, modeID)) &&
        !IsWindowEnabled(GetDlgItem(window, modelID)) && observed.model == 1;
    jsti_window_update(nullptr, nullptr, 0);
    applyUpdate(window);
    if (!cancellation) { failure = "Busy transcription could not be cancelled from the native control."; return false; }
    {
        MSG escape{};
        escape.hwnd = GetDlgItem(window, transcriptID);
        escape.message = WM_KEYDOWN; escape.wParam = VK_ESCAPE;
        const int before = observed.calls;
        const bool savedPolicy = jsti::globalEscape::enabled();
        bool okay = jsti_window_set_escape_cancellation(1) == 0 && !cancelKey(window, escape, true, true);
        jsti_window_update(nullptr, nullptr, 1);
        applyUpdate(window);
        okay = !cancelKey(window, escape, false, true) && !cancelKey(window, escape, true, false) && okay;
        HWND child = escape.hwnd;
        escape.hwnd = GetDesktopWindow();
        okay = !cancelKey(window, escape, true, true) && okay;
        escape.hwnd = child;
        EnableWindow(window, FALSE);
        okay = !cancelKey(window, escape, true, true) && okay;
        EnableWindow(window, TRUE);
        okay = cancelKey(window, escape, true, true) && observed.calls == before + 1 &&
            observed.event == JSTI_EVENT_CANCEL_TRANSCRIPTION &&
            observed.id == std::to_string(jsti::globalEscape::token()) && okay;
        escape.lParam = static_cast<LPARAM>(1) << 30;
        okay = cancelKey(window, escape, true, true) && observed.calls == before + 1 && okay;
        jsti_window_update(nullptr, nullptr, 0);
        applyUpdate(window);
        okay = cancelKey(window, escape, true, true) && observed.calls == before + 1 && okay;
        escape.message = WM_KEYUP;
        okay = cancelKey(window, escape, true, true) && !state.cancelKeyHeld && okay;
        escape.message = WM_KEYDOWN;
        okay = !cancelKey(window, escape, true, true) && okay;
        jsti_window_update(nullptr, nullptr, 2);
        applyUpdate(window);
        escape.lParam = 0;
        okay = cancelKey(window, escape, true, true) && observed.calls == before + 2 && okay;
        const auto oldToken = jsti::globalEscape::token();
        okay = jsti_window_set_escape_cancellation(-1) == -1 &&
            jsti_window_set_escape_cancellation(2) == -1 &&
            jsti_window_set_voice_edit_escape(-1) == -1 &&
            jsti_window_set_voice_edit_escape(2) == -1 &&
            jsti_window_global_escape_is_current(oldToken) == 1 && okay;
        okay = jsti_window_set_escape_cancellation(0) == 0 &&
            !cancelKey(window, escape, true, true) && observed.calls == before + 2 &&
            !jsti_window_global_escape_is_current(oldToken) && okay;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
        okay = observed.calls == before + 3 && observed.event == JSTI_EVENT_CANCEL_TRANSCRIPTION &&
            observed.id.empty() && okay;
        okay = jsti_window_set_escape_cancellation(1) == 0 &&
            !jsti_window_global_escape_is_current(oldToken) &&
            cancelKey(window, escape, true, true) && observed.calls == before + 3 && okay;
        SendMessageW(window, WM_ACTIVATE, WA_INACTIVE, 0);
        okay = !state.cancelKeyHeld && okay;
        okay = cancelKey(window, escape, true, true) && observed.calls == before + 4 &&
            observed.id == std::to_string(jsti::globalEscape::token()) && okay;
        escape.message = WM_KEYUP;
        okay = cancelKey(window, escape, true, true) && !state.cancelKeyHeld && okay;
        jsti_window_update(nullptr, nullptr, 0);
        applyUpdate(window);
        okay = jsti_window_set_escape_cancellation(savedPolicy ? 1 : 0) == 0 && okay;
        if (!okay) { failure = "Escape cancellation lost ownership, idle or repeat guards."; return false; }
    }
    return true;
}

} // namespace jsti_window
