// History page: selection, search, transcript variants, playback and export.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {

std::string historyManagementIDs() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.history.allHistoryIDs;
}

std::string selectedHistory(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
    if (index == LB_ERR || static_cast<size_t>(index) >= state.history.displayedHistory.size()) return {};
    return state.history.displayedHistory[static_cast<size_t>(index)].id;
}

bool searching(HWND window) { return GetWindowTextLengthW(GetDlgItem(window, searchID)) > 0; }

// The variant control never infers a version: it shows only what the host
// reported for the selected record, and a user choice is echoed back by event.
void applyVariant(HWND window, int selected, bool switchable, int recording) {
    state.history.displayedVariant = selected == 0 || selected == 1 ? selected : -1;
    state.history.variantSwitchable = switchable && state.history.displayedVariant >= 0;
    SendDlgItemMessageW(window, variantID, CB_SETCURSEL,
        state.history.displayedVariant < 0 ? static_cast<WPARAM>(-1) : static_cast<WPARAM>(state.history.displayedVariant), 0);
    EnableWindow(GetDlgItem(window, variantID), state.history.variantSwitchable && recording == 0);
}

// Play/Pause is available for a selected idle record, or whenever a playback
// is active so it can always be paused; Stop only while a playback is active.
// The label follows the state the host acknowledged, never a click.
void updatePlaybackControls(HWND window, bool selected, int recording) {
    const bool active = state.history.displayedPlayback != playbackIdle;
    SetDlgItemTextW(window, playPauseID,
        state.history.displayedPlayback == playbackPreparing || state.history.displayedPlayback == playbackPlaying ? L"Pause" : L"Play");
    EnableWindow(GetDlgItem(window, playPauseID), (selected && recording == 0) || active);
    EnableWindow(GetDlgItem(window, stopPlaybackID), active || (state.page == voicePage && recording == 0));
}

// The playback display never infers progress: it shows only what the host
// reported for the selected record, and controls are echoed back by event.
void applyPlayback(HWND window, int playback, const std::wstring &text, bool selected, int recording) {
    state.history.displayedPlayback = playback >= playbackIdle && playback <= playbackPaused ? playback : playbackIdle;
    SetDlgItemTextW(window, playbackTimeID, text.empty() ? playbackIdleText : text.c_str());
    updatePlaybackControls(window, selected, recording);
}

void updateHistoryControls(HWND window, int recording) {
    const LRESULT index = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
    const bool selected = index != LB_ERR && static_cast<size_t>(index) < state.history.displayedHistory.size();
    const bool filtering = searching(window) || jsti_history_filters_active();
    if (!selected && state.history.displayedPlayback != playbackIdle) applyPlayback(window, playbackIdle, L"", false, recording);
    else updatePlaybackControls(window, selected, recording);
    SetDlgItemTextW(window, historyDetailID, selected ? state.history.displayedHistory[static_cast<size_t>(index)].detail.c_str()
        : (state.history.displayedHistory.empty()
            ? (filtering ? L"No saved recordings match this search or filter." : L"Your saved recordings will appear here.")
            : L"Select a saved recording."));
    EnableWindow(GetDlgItem(window, historyID), recording == 0);
    EnableWindow(GetDlgItem(window, searchID), recording == 0);
    EnableWindow(GetDlgItem(window, historyFiltersID), recording == 0);
    EnableWindow(GetDlgItem(window, historyDeleteID), recording == 0 && selected);
    EnableWindow(GetDlgItem(window, historyClearID), recording == 0 && !historyManagementIDs().empty());
    EnableWindow(GetDlgItem(window, audioCleanupID), recording == 0);
    EnableWindow(GetDlgItem(window, backupAudioID), recording == 0);
    EnableWindow(GetDlgItem(window, backupProfilesID), recording == 0);
    EnableWindow(GetDlgItem(window, backupExportID), recording == 0);
    EnableWindow(GetDlgItem(window, backupInspectID), recording == 0);
    EnableWindow(GetDlgItem(window, backupRestoreID), recording == 0);
    jsti_history_filters_enabled(recording == 0);
    SetDlgItemTextW(window, historyFiltersID, jsti_history_filters_label().c_str());
    EnableWindow(GetDlgItem(window, clearSearchID), recording == 0 && searching(window));
    for (int id : {retryID, openAudioID}) EnableWindow(GetDlgItem(window, id), selected && recording == 0);
    EnableWindow(GetDlgItem(window, historyCorrectionsID), selected && recording == 0 && state.history.historyPresentationReady);
    EnableWindow(GetDlgItem(window, exportID), selected && recording == 0 && state.history.historyPresentationReady);
    EnableWindow(GetDlgItem(window, issueReportID), selected && recording == 0 && state.history.historyPresentationReady);
    EnableWindow(GetDlgItem(window, readAloudID), selected && recording == 0 && state.history.historyPresentationReady &&
        jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, voiceSettingsID), recording == 0 && jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, voiceSourcesID), recording == 0 && jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, voiceCredentialID), recording == 0 && jsti_voice_credentials_available());
    EnableWindow(GetDlgItem(window, copyID), state.history.historyPresentationReady && (!selected || recording == 0));
    if (!selected) applyVariant(window, -1, false, recording);
    else EnableWindow(GetDlgItem(window, variantID), state.history.variantSwitchable && recording == 0);
}

// Clear stale text synchronously, before the async host sees this UI event.
void invalidateHistoryPresentation(HWND window, bool resetVersion) {
    state.history.historyPresentationReady = false;
    if (resetVersion) state.history.requestedVariant = -1;
    SetDlgItemTextW(window, transcriptID, L"");
    SetDlgItemTextW(window, statusID, selectedHistory(window).empty()
        ? L"Select a saved recording." : L"Loading saved transcript…");
    EnableWindow(GetDlgItem(window, copyID), FALSE);
    EnableWindow(GetDlgItem(window, exportID), FALSE);
    EnableWindow(GetDlgItem(window, issueReportID), FALSE);
    EnableWindow(GetDlgItem(window, readAloudID), FALSE);
}

void emitHistory(HWND window, int event) {
    const std::string id = selectedHistory(window);
    if (!id.empty()) emit(window, event, id.c_str());
}

std::wstring searchText(HWND window) {
    const HWND control = GetDlgItem(window, searchID);
    const int length = std::max(GetWindowTextLengthW(control), 0);
    std::wstring text(static_cast<size_t>(length) + 1, 0);
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}

// Every keystroke reports the whole current query; the host coalesces bursts
// and answers with a replacement snapshot, so no filtering happens here.
void searchChanged(HWND window) {
    if (state.history.suppressSearchEvents) return;
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    EnableWindow(GetDlgItem(window, clearSearchID), recording == 0 && searching(window));
    const std::string query = jsti::utf8(searchText(window));
    emit(window, JSTI_EVENT_HISTORY_SEARCH, query.c_str());
}

void clearSearch(HWND window) {
    if (!searching(window)) return;
    state.history.suppressSearchEvents = true;
    SetDlgItemTextW(window, searchID, L"");
    state.history.suppressSearchEvents = false;
    searchChanged(window);
    if (GetActiveWindow() == window) SetFocus(GetDlgItem(window, searchID));
}
} // namespace jsti_window

int jsti_window_set_history_management(const char *identifiers) {
    std::wstring checked;
    if (!identifiers || !jsti::wide(identifiers, checked)) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    state.history.allHistoryIDs = identifiers;
    if (state.window && !state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

int jsti_window_set_history(const JSTIHistoryRow *rows, size_t count, const char *selectedID) {
    if ((!rows && count) || count > 10000) return -1;
    try {
        std::vector<HistoryRow> copied;
        copied.reserve(count);
        std::unordered_set<std::string> identifiers;
        for (size_t i = 0; i < count; ++i) {
            HistoryRow row;
            std::wstring identifier;
            if (!jsti::wide(rows[i].id, identifier) || identifier.empty() || identifier.size() > 128 ||
                !jsti::wide(rows[i].title, row.title) || !jsti::wide(rows[i].detail, row.detail)) return -1;
            if (row.title.size() > 4096 || row.detail.size() > 16384) return -1;
            // The card fields are optional; absent ones hide their badge.
            auto optional = [](const char *value, std::wstring &target) {
                return !value || (jsti::wide(value, target) && target.size() <= 4096);
            };
            if (!optional(rows[i].created, row.created) || !optional(rows[i].audio_length, row.audio) ||
                !optional(rows[i].cost, row.cost) || !optional(rows[i].preview, row.preview) ||
                !optional(rows[i].models, row.models) || !optional(rows[i].context, row.context) ||
                rows[i].tone < 0 || rows[i].tone > 2) return -1;
            row.tone = rows[i].tone;
            row.id = rows[i].id;
            if (!identifiers.insert(row.id).second) return -1;
            copied.push_back(std::move(row));
        }
        std::wstring checkedSelection;
        if (selectedID && !jsti::wide(selectedID, checkedSelection)) return -1;
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.history.pendingHistory = std::move(copied);
        state.history.historySelectionProvided = selectedID != nullptr;
        state.history.pendingHistoryRevision = state.history.historyInteractionRevision;
        state.history.pendingHistorySelection = selectedID ? selectedID : "";
        state.history.historyChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) {
        return -1;
    }
}

int jsti_window_set_transcript_variant(const char *recordID, int selected, int canSwitch) {
    if (selected < -1 || selected > 1 || (canSwitch != 0 && canSwitch != 1)) return -1;
    std::wstring checked;
    if (recordID && (!jsti::wide(recordID, checked) || checked.size() > 128)) return -1;
    try {
        std::string record = recordID ? recordID : "";
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.history.pendingVariant = record.empty() ? -1 : selected;
        state.history.pendingVariantRecord = std::move(record);
        state.history.pendingVariantSwitchable = canSwitch != 0;
        state.history.variantChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_history_presentation(const char *recordID, int selected, int canSwitch,
    const char *transcript, const char *status) {
    if (!recordID || !*recordID || selected < -1 || selected > 1 || (canSwitch != 0 && canSwitch != 1)) return -1;
    try {
        HistoryPresentation presentation;
        std::wstring validatedID;
        if (!jsti::wide(recordID, validatedID) || validatedID.size() > 128 ||
            !jsti::wide(transcript, presentation.transcript) ||
            !jsti::wide(status, presentation.status)) return -1;
        presentation.record = recordID;
        presentation.variant = selected;
        presentation.switchable = canSwitch != 0;
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.history.pendingPresentation = std::move(presentation);
        state.history.presentationChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_transcript_snapshot(char *text, size_t capacity, size_t *required) {
    if (!required) return -1;
    *required = 0;
    HWND window;
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; recording = state.recording; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) return -1;
    if (!state.history.historyPresentationReady || (!selectedHistory(window).empty() && recording != 0)) return -1;
    try {
        constexpr size_t maximum = 8 * 1024 * 1024;
        HWND control = GetDlgItem(window, transcriptID);
        SetLastError(ERROR_SUCCESS);
        const int length = GetWindowTextLengthW(control);
        if ((length == 0 && GetLastError() != ERROR_SUCCESS) || length < 0 ||
            static_cast<size_t>(length) > maximum) return -1;
        std::vector<wchar_t> wide(static_cast<size_t>(length) + 1);
        if (GetWindowTextW(control, wide.data(), length + 1) != length) return -1;
        const std::string value = jsti::utf8(wide.data());
        if ((length != 0 && value.empty()) || value.size() > maximum) return -1;
        *required = value.size() + 1;
        if (!text || capacity < *required) return 2;
        std::memcpy(text, value.c_str(), *required);
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_transcript_variant(void) {
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) return -1;
    return selectedHistory(window).empty() ? -1 : state.history.displayedVariant;
}

int jsti_window_set_playback(const char *recordID, int playback, const char *timeText) {
    if (playback < playbackIdle || playback > playbackPaused) return -1;
    std::wstring checkedRecord, text;
    if (recordID && (!jsti::wide(recordID, checkedRecord) || checkedRecord.size() > 128)) return -1;
    if (timeText && (!jsti::wide(timeText, text) || text.size() > 256)) return -1;
    try {
        std::string record = recordID ? recordID : "";
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.history.pendingPlaybackState = record.empty() ? playbackIdle : playback;
        state.history.pendingPlaybackRecord = std::move(record);
        state.history.pendingPlaybackText = std::move(text);
        state.history.playbackChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_choose_export_path(const char *suggestedFilename, char *path, size_t pathCapacity,
                                   char *error, size_t errorCapacity) {
    if (!path || !pathCapacity) return jsti::fail("No export path buffer supplied.", error, errorCapacity);
    path[0] = 0;
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("The export dialog must be opened from the desktop window callback.", error, errorCapacity);
    }
    std::wstring suggestion;
    if (!jsti::wide(suggestedFilename ? suggestedFilename : "transcript.txt", suggestion) ||
        suggestion.empty() || suggestion.size() > 255 || suggestion.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos) {
        return jsti::fail("The suggested export filename is invalid.", error, errorCapacity);
    }
    std::vector<wchar_t> destination(32768);
    std::copy(suggestion.begin(), suggestion.end(), destination.begin());
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFilter = L"Text documents (*.txt)\0*.txt\0\0";
    chooser.lpstrFile = destination.data();
    chooser.nMaxFile = static_cast<DWORD>(destination.size());
    chooser.lpstrDefExt = L"txt";
    chooser.lpstrTitle = L"Export saved transcript";
    chooser.Flags = OFN_PATHMUSTEXIST | OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_DONTADDTORECENT;
    if (!GetSaveFileNameW(&chooser)) {
        const DWORD code = CommDlgExtendedError();
        return code ? jsti::fail(jsti::systemError("Choosing transcript export path", code), error, errorCapacity) : 1;
    }
    const std::string result = jsti::utf8(destination.data());
    if (result.empty()) return jsti::fail("Windows returned an invalid export path.", error, errorCapacity);
    if (result.size() + 1 > pathCapacity) {
        return jsti::fail("The export path exceeds the caller's buffer capacity. Choose a shorter path.", error, errorCapacity);
    }
    std::memcpy(path, result.c_str(), result.size() + 1);
    return 0;
}

int jsti_shell_open_file(const char *path, char *error, size_t errorCapacity) {
    std::wstring filename;
    if (!jsti::wide(path, filename) || filename.empty()) return jsti::fail("No valid audio path supplied.", error, errorCapacity);
    const DWORD attributes = GetFileAttributesW(filename.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) return jsti::fail(jsti::systemError("Finding saved audio"), error, errorCapacity);
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) return jsti::fail("The audio path refers to a directory.", error, errorCapacity);
    const size_t dot = filename.find_last_of(L'.');
    const wchar_t *extension = dot == std::wstring::npos ? L"" : filename.c_str() + dot;
    const wchar_t *audioExtensions[] = {L".wav", L".mp3", L".m4a", L".flac", L".ogg", L".opus", L".webm",
                                       L".mp4", L".mpeg", L".mpga", L".aac", L".aif", L".aiff", L".wma"};
    bool isAudio = false;
    for (const auto allowed : audioExtensions) if (_wcsicmp(extension, allowed) == 0) { isAudio = true; break; }
    if (!isAudio) return jsti::fail("This saved file does not have a supported audio extension.", error, errorCapacity);
    const INT_PTR launched = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", filename.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (launched <= 32) return jsti::fail(jsti::systemError("Opening saved audio", static_cast<DWORD>(launched)), error, errorCapacity);
    return 0;
}

int jsti_shell_open_directory(const char *path, char *error, size_t errorCapacity) {
    std::wstring folder;
    if (!jsti::wide(path, folder) || folder.empty()) {
        return jsti::fail("No valid recording folder supplied.", error, errorCapacity);
    }
    const DWORD attributes = GetFileAttributesW(folder.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        return jsti::fail("The recording folder does not exist or is not a directory.", error, errorCapacity);
    }
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) {
        return jsti::fail("Windows could not initialize the folder launcher.", error, errorCapacity);
    }
    PIDLIST_ABSOLUTE item = ILCreateFromPathW(folder.c_str());
    const HRESULT opened = item ? SHOpenFolderAndSelectItems(item, 0, nullptr, 0) : E_INVALIDARG;
    CoTaskMemFree(item);
    if (SUCCEEDED(apartment)) CoUninitialize();
    if (FAILED(opened)) return jsti::fail("Windows could not reveal the recording folder.", error, errorCapacity);
    return 0;
}
