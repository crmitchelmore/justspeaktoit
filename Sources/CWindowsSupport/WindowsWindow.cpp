#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <shellapi.h>
#include <mutex>
#include <unordered_set>
#include <vector>

bool jsti_postprocessing_available();
void jsti_show_postprocessing(HWND owner);
bool jsti_settings_self_test(HWND owner, std::string &error);

namespace {
constexpr UINT updateMessage = WM_APP + 1;
constexpr int hotkeyID = 1;
enum Control {
    modelID = 100, keyID, saveID, recordID, importID, copyID, transcriptID, statusID,
    historyID, historyDetailID, retryID, exportID, openAudioID, processingID, microphoneID, modeID
};
struct HistoryRow {
    std::string id;
    std::wstring title;
    std::wstring detail;
};
struct MicrophoneRow { std::string id; std::wstring name; };
struct WindowState {
    std::mutex mutex;
    HWND window = nullptr;
    bool running = false;
    bool posted = false;
    bool statusChanged = false;
    bool transcriptChanged = false;
    bool historyChanged = false;
    bool historySelectionProvided = false;
    int recording = 0;
    std::wstring status;
    std::wstring transcript;
    std::vector<MicrophoneRow> microphones;
    std::string microphoneSelection;
    std::vector<int> configuredModelModes;
    int configuredPreferredModels[2] = {-1, -1};
    std::vector<HistoryRow> pendingHistory;
    std::string pendingHistorySelection;
    std::string selectedHistoryID;
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    // Only accessed by the UI thread. Pending snapshots above use mutex.
    std::vector<HistoryRow> displayedHistory;
    std::vector<std::wstring> modelNames;
    std::vector<int> modelModes;
    std::vector<int> filteredModels;
    int preferredModels[2] = {-1, -1};
    int activeMode = 0;
} state;

int selection(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    return index == CB_ERR || static_cast<size_t>(index) >= state.filteredModels.size()
        ? -1 : state.filteredModels[static_cast<size_t>(index)];
}

bool hasModeChoice() {
    return state.preferredModels[0] >= 0 && state.preferredModels[1] >= 0;
}

bool liveSelection(HWND window) {
    const int selected = selection(window);
    return selected >= 0 && static_cast<size_t>(selected) < state.modelModes.size() && state.modelModes[selected] == 1;
}

void updateModelAvailability(HWND window, int recording) {
    EnableWindow(GetDlgItem(window, modeID), recording == 0 && hasModeChoice());
    EnableWindow(GetDlgItem(window, modelID), recording == 0);
    EnableWindow(GetDlgItem(window, importID), recording == 0 && selection(window) >= 0 && !liveSelection(window));
}

bool idleControl(HWND window, int identifier) {
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    return recording == 0 && IsWindowEnabled(GetDlgItem(window, identifier));
}

bool populateModels(HWND window) {
    HWND combo = GetDlgItem(window, modelID);
    SendMessageW(combo, WM_SETREDRAW, FALSE, 0);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    state.filteredModels.clear();
    LRESULT selectedRow = CB_ERR;
    bool success = true;
    for (size_t index = 0; index < state.modelNames.size(); ++index) {
        if (state.modelModes[index] != state.activeMode) continue;
        const LRESULT row = SendMessageW(combo, CB_ADDSTRING, 0,
                                         reinterpret_cast<LPARAM>(state.modelNames[index].c_str()));
        if (row == CB_ERR || row == CB_ERRSPACE) { success = false; break; }
        state.filteredModels.push_back(static_cast<int>(index));
        if (static_cast<int>(index) == state.preferredModels[state.activeMode]) selectedRow = row;
    }
    if (selectedRow == CB_ERR || !success) {
        SendMessageW(combo, CB_RESETCONTENT, 0, 0);
        state.filteredModels.clear();
        success = false;
    } else SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(selectedRow), 0);
    SendMessageW(combo, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(combo, nullptr, TRUE);
    const bool choice = hasModeChoice();
    ShowWindow(GetDlgItem(window, modeID), choice ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(window, 95), choice ? SW_SHOW : SW_HIDE);
    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, state.activeMode, 0);
    SetDlgItemTextW(window, 90, !choice && state.activeMode == 1 ? L"Live &transcription model" : L"&Transcription model");
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    updateModelAvailability(window, recording);
    return success;
}

void emit(HWND window, int event, const char *text = "") {
    if (state.callback) state.callback(event, text, selection(window), state.context);
}

std::string selectedMicrophone(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, microphoneID, CB_GETCURSEL, 0, 0);
    if (index == CB_ERR || static_cast<size_t>(index) >= state.microphones.size()) return {};
    return state.microphones[static_cast<size_t>(index)].id;
}

void emitRecording(HWND window) {
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    if (recording == 2) { emit(window, JSTI_EVENT_CANCEL_TRANSCRIPTION); return; }
    const std::string device = selectedMicrophone(window);
    emit(window, JSTI_EVENT_TOGGLE_RECORDING, device.c_str());
}

void showFailure(HWND window, const std::string &message) {
    emit(window, JSTI_EVENT_ERROR, message.c_str());
    std::wstring wide;
    if (jsti::wide(message.c_str(), wide)) SetDlgItemTextW(window, statusID, wide.c_str());
}

std::string selectedHistory(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
    if (index == LB_ERR || static_cast<size_t>(index) >= state.displayedHistory.size()) return {};
    return state.displayedHistory[static_cast<size_t>(index)].id;
}

void updateHistoryControls(HWND window, int recording) {
    const LRESULT index = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
    const bool selected = index != LB_ERR && static_cast<size_t>(index) < state.displayedHistory.size();
    SetDlgItemTextW(window, historyDetailID, selected ? state.displayedHistory[static_cast<size_t>(index)].detail.c_str()
        : (state.displayedHistory.empty() ? L"Your saved recordings will appear here." : L"Select a saved recording."));
    EnableWindow(GetDlgItem(window, historyID), recording == 0);
    for (int id : {retryID, exportID, openAudioID}) EnableWindow(GetDlgItem(window, id), selected && recording == 0);
}

void emitHistory(HWND window, int event) {
    const std::string id = selectedHistory(window);
    if (!id.empty()) emit(window, event, id.c_str());
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    const int margin = scale(window, 20);
    const int gap = scale(window, 12);
    const int row = scale(window, 34);
    const int availableWidth = std::max(scale(window, 740), static_cast<int>(bounds.right) - 2 * margin);
    const int historyWidth = std::min(scale(window, 300), std::max(scale(window, 240), availableWidth / 3));
    const int contentLeft = margin + historyWidth + margin;
    const int width = availableWidth - historyWidth - margin;
    const int saveWidth = scale(window, 112);
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    const int modelTop = margin + (hasModeChoice() ? row : 0);
    move(95, contentLeft, margin + scale(window, 3), scale(window, 64), scale(window, 22));
    move(modeID, contentLeft + scale(window, 70), margin, width - scale(window, 70), scale(window, 160));
    move(90, contentLeft, modelTop, width, scale(window, 22));
    const int settingsWidth = scale(window, 148);
    move(modelID, contentLeft, modelTop + scale(window, 26), width - settingsWidth - gap, scale(window, 260));
    move(processingID, contentLeft + width - settingsWidth, modelTop + scale(window, 26), settingsWidth, row);
    move(91, contentLeft, modelTop + scale(window, 70), width, scale(window, 22));
    const int keyTop = modelTop + scale(window, 96);
    move(keyID, contentLeft, keyTop, width - saveWidth - gap, row);
    move(saveID, contentLeft + width - saveWidth, keyTop, saveWidth, row);
    const int microphoneTop = keyTop + row + gap;
    move(94, contentLeft, microphoneTop, width, scale(window, 22));
    move(microphoneID, contentLeft, microphoneTop + scale(window, 26), width, scale(window, 260));
    const int actionsTop = microphoneTop + scale(window, 26) + row + gap;
    const int actionWidth = (width - 2 * gap) / 3;
    move(recordID, contentLeft, actionsTop, actionWidth, row);
    move(importID, contentLeft + actionWidth + gap, actionsTop, actionWidth, row);
    move(copyID, contentLeft + 2 * (actionWidth + gap), actionsTop, actionWidth, row);
    move(92, contentLeft, actionsTop + row + gap, width, scale(window, 22));
    const int transcriptTop = actionsTop + row + scale(window, 38);
    const int statusHeight = scale(window, 64);
    const int transcriptHeight = std::max(scale(window, 80), static_cast<int>(bounds.bottom) - transcriptTop - statusHeight - 2 * margin);
    move(transcriptID, contentLeft, transcriptTop, width, transcriptHeight);
    move(statusID, contentLeft, transcriptTop + transcriptHeight + gap, width, statusHeight);
    move(93, margin, margin, historyWidth, scale(window, 22));
    const int historyTop = margin + scale(window, 26);
    const int detailHeight = scale(window, 72);
    const int historyHeight = std::max(scale(window, 120), static_cast<int>(bounds.bottom) - historyTop -
        detailHeight - 2 * row - 3 * gap - margin);
    move(historyID, margin, historyTop, historyWidth, historyHeight);
    const int detailTop = historyTop + historyHeight + gap;
    move(historyDetailID, margin, detailTop, historyWidth, detailHeight);
    const int buttonsTop = detailTop + detailHeight + gap;
    const int buttonWidth = (historyWidth - gap) / 2;
    move(retryID, margin, buttonsTop, buttonWidth, row);
    move(exportID, margin + buttonWidth + gap, buttonsTop, buttonWidth, row);
    move(openAudioID, margin, buttonsTop + row + gap, historyWidth, row);
}

void refreshFont(HWND window) {
    HFONT replacement = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72),
        0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!replacement) return;
    for (HWND control : state.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(replacement), TRUE);
    if (state.font) DeleteObject(state.font);
    state.font = replacement;
}

bool createControls(HWND window) {
    auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int identifier) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 || wcscmp(kind, L"LISTBOX") == 0 ? WS_EX_CLIENTEDGE : 0, kind, label,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(identifier)), GetModuleHandleW(nullptr), nullptr);
        if (control) state.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay = add(L"STATIC", L"&History", 0, 93) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, historyID) &&
        add(L"STATIC", L"Your saved recordings will appear here.", SS_LEFT, historyDetailID) &&
        add(L"BUTTON", L"Retr&y", BS_PUSHBUTTON | WS_TABSTOP, retryID) &&
        add(L"BUTTON", L"&Export text", BS_PUSHBUTTON | WS_TABSTOP, exportID) &&
        add(L"BUTTON", L"&Open audio", BS_PUSHBUTTON | WS_TABSTOP, openAudioID) &&
        add(L"STATIC", L"&Mode", 0, 95) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, modeID) &&
        add(L"STATIC", L"&Transcription model", 0, 90) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"BUTTON", L"&Post-processing…", BS_PUSHBUTTON | WS_TABSTOP, processingID) &&
        add(L"STATIC", L"&API key (Windows Credential Manager)", 0, 91) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"STATIC", L"&Microphone", 0, 94) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, microphoneID) &&
        add(L"BUTTON", L"&Record", BS_PUSHBUTTON | WS_TABSTOP, recordID) &&
        add(L"BUTTON", L"&Import audio", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"BUTTON", L"&Copy transcript", BS_PUSHBUTTON | WS_TABSTOP, copyID) &&
        add(L"STATIC", L"Transcript — Ctrl+Alt+Space starts or stops recording", 0, 92) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, transcriptID) &&
        add(L"STATIC", L"Ready. Choose a model and save its API key to begin.", SS_LEFT, statusID);
    LRESULT selectedDevice = 0;
    for (size_t i = 0; i < state.microphones.size(); ++i) {
        const auto &device = state.microphones[i];
        const LRESULT added = SendDlgItemMessageW(window, microphoneID, CB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(device.name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
        if (device.id == state.microphoneSelection) selectedDevice = static_cast<LRESULT>(i);
    }
    SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, selectedDevice, 0);
    SendDlgItemMessageW(window, keyID, EM_LIMITTEXT, 2048, 0);
    SendDlgItemMessageW(window, transcriptID, EM_LIMITTEXT, 4 * 1024 * 1024, 0);
    refreshFont(window);
    if (SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Batch")) < 0 ||
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Live")) < 0 ||
        !populateModels(window)) return false;
    updateHistoryControls(window, 0);
    EnableWindow(GetDlgItem(window, processingID), jsti_postprocessing_available());
    return okay;
}

void applyUpdate(HWND window) {
    std::wstring status, transcript;
    bool statusChanged, transcriptChanged, historyChanged;
    std::vector<HistoryRow> history;
    std::string historySelection;
    int recording;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        status.swap(state.status); transcript.swap(state.transcript);
        statusChanged = state.statusChanged; transcriptChanged = state.transcriptChanged;
        state.statusChanged = false; state.transcriptChanged = false;
        historyChanged = state.historyChanged;
        if (historyChanged) {
            history = std::move(state.pendingHistory);
            historySelection = state.historySelectionProvided ? state.pendingHistorySelection : state.selectedHistoryID;
            state.historyChanged = false;
        }
        state.posted = false;
        recording = state.recording;
    }
    if (statusChanged) SetDlgItemTextW(window, statusID, status.c_str());
    if (transcriptChanged) SetDlgItemTextW(window, transcriptID, transcript.c_str());
    SetDlgItemTextW(window, recordID, recording == 1 ? L"&Stop recording" : (recording == 2 ? L"&Cancel transcription" : L"&Record"));
    EnableWindow(GetDlgItem(window, recordID), TRUE);
    for (int id : {keyID, saveID, microphoneID}) EnableWindow(GetDlgItem(window, id), recording == 0);
    updateModelAvailability(window, recording);
    EnableWindow(GetDlgItem(window, processingID), recording == 0 && jsti_postprocessing_available());
    if (historyChanged) {
        HWND list = GetDlgItem(window, historyID);
        const LRESULT oldTop = SendMessageW(list, LB_GETTOPINDEX, 0, 0);
        SendMessageW(list, WM_SETREDRAW, FALSE, 0);
        SendMessageW(list, LB_RESETCONTENT, 0, 0);
        state.displayedHistory = std::move(history);
        LRESULT selectedIndex = LB_ERR;
        bool failed = false;
        for (size_t i = 0; i < state.displayedHistory.size(); ++i) {
            const auto &entry = state.displayedHistory[i];
            const LRESULT added = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(entry.title.c_str()));
            if (added == LB_ERR || added == LB_ERRSPACE) { failed = true; break; }
            if (entry.id == historySelection) selectedIndex = static_cast<LRESULT>(i);
        }
        if (failed) {
            SendMessageW(list, LB_RESETCONTENT, 0, 0);
            state.displayedHistory.clear();
            selectedIndex = LB_ERR;
        }
        SendMessageW(list, LB_SETCURSEL, static_cast<WPARAM>(selectedIndex), 0);
        if (oldTop > 0 && static_cast<size_t>(oldTop) < state.displayedHistory.size()) {
            SendMessageW(list, LB_SETTOPINDEX, static_cast<WPARAM>(oldTop), 0);
        }
        SendMessageW(list, WM_SETREDRAW, TRUE, 0);
        InvalidateRect(list, nullptr, TRUE);
        { std::lock_guard<std::mutex> lock(state.mutex); state.selectedHistoryID = selectedHistory(window); }
        if (failed) showFailure(window, "Windows could not display the saved recording list.");
    }
    updateHistoryControls(window, recording);
}

void importAudio(HWND window) {
    std::vector<wchar_t> path(32768);
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFilter = L"Audio files\0*.wav;*.mp3;*.mp4;*.m4a;*.aac;*.flac;*.ogg;*.opus;*.webm\0\0";
    chooser.lpstrFile = path.data();
    chooser.nMaxFile = static_cast<DWORD>(path.size());
    chooser.lpstrTitle = L"Choose audio to transcribe";
    chooser.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (GetOpenFileNameW(&chooser)) {
        const std::string text = jsti::utf8(path.data());
        emit(window, JSTI_EVENT_IMPORT_AUDIO, text.c_str());
    } else {
        const DWORD error = CommDlgExtendedError();
        if (error) showFailure(window, jsti::systemError("Opening audio picker", error));
    }
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_CREATE:
        return createControls(window) ? 0 : -1;
    case WM_GETMINMAXINFO: {
        auto info = reinterpret_cast<MINMAXINFO *>(lparam);
        info->ptMinTrackSize = {scale(window, 820), scale(window, hasModeChoice() ? 634 : 600)};
        return 0;
    }
    case WM_SIZE:
        layout(window); return 0;
    case WM_DPICHANGED: {
        auto bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window); layout(window); return 0;
    }
    case updateMessage:
        applyUpdate(window); return 0;
    case WM_HOTKEY:
        if (wparam == hotkeyID && IsWindowEnabled(GetDlgItem(window, recordID))) emitRecording(window);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case recordID: emitRecording(window); return 0;
        case importID:
            if (idleControl(window, importID) && !liveSelection(window)) importAudio(window);
            return 0;
        case copyID: {
            const std::string id = selectedHistory(window);
            emit(window, JSTI_EVENT_COPY_TRANSCRIPT, id.c_str());
            return 0;
        }
        case processingID: jsti_show_postprocessing(window); return 0;
        case retryID: emitHistory(window, JSTI_EVENT_HISTORY_RETRY); return 0;
        case exportID: emitHistory(window, JSTI_EVENT_HISTORY_EXPORT); return 0;
        case openAudioID: emitHistory(window, JSTI_EVENT_HISTORY_OPEN_AUDIO); return 0;
        case historyID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                int recording;
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    state.selectedHistoryID = selectedHistory(window);
                    recording = state.recording;
                }
                updateHistoryControls(window, recording);
                emitHistory(window, JSTI_EVENT_HISTORY_SELECTED);
            }
            return 0;
        case microphoneID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const std::string device = selectedMicrophone(window);
                emit(window, JSTI_EVENT_MICROPHONE_CHANGED, device.c_str());
            }
            return 0;
        case modelID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, modelID)) {
                    const auto previous = std::find(state.filteredModels.begin(), state.filteredModels.end(),
                                                     state.preferredModels[state.activeMode]);
                    if (previous != state.filteredModels.end()) SendDlgItemMessageW(window, modelID, CB_SETCURSEL,
                        static_cast<WPARAM>(previous - state.filteredModels.begin()), 0);
                    return 0;
                }
                const int selected = selection(window);
                if (selected < 0) return 0;
                state.preferredModels[state.activeMode] = selected;
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
            }
            return 0;
        case modeID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, modeID)) {
                    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, state.activeMode, 0);
                    return 0;
                }
                const LRESULT mode = SendDlgItemMessageW(window, modeID, CB_GETCURSEL, 0, 0);
                if ((mode != 0 && mode != 1) || state.preferredModels[mode] < 0) return 0;
                state.activeMode = static_cast<int>(mode);
                if (!populateModels(window)) { showFailure(window, "Windows could not display this mode's models."); return 0; }
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
            }
            return 0;
        case saveID: {
            const int count = GetWindowTextLengthW(GetDlgItem(window, keyID));
            if (count <= 0) { showFailure(window, "Enter an API key before saving."); return 0; }
            std::wstring secret(static_cast<size_t>(count) + 1, 0);
            GetDlgItemTextW(window, keyID, &secret[0], count + 1);
            secret.resize(count);
            std::string text = jsti::utf8(secret);
            emit(window, JSTI_EVENT_SAVE_CREDENTIAL, text.c_str());
            SetDlgItemTextW(window, keyID, L"");
            SecureZeroMemory(&secret[0], secret.size() * sizeof(wchar_t));
            if (!text.empty()) SecureZeroMemory(&text[0], text.size());
            return 0;
        }
        }
        break;
    case WM_CLOSE:
        emit(window, JSTI_EVENT_CLOSING);
        DestroyWindow(window); return 0;
    case WM_DESTROY:
        UnregisterHotKey(window, hotkeyID);
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = nullptr; state.posted = false; }
        PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

int jsti_window_run(const char *const *models, size_t count, int selected,
                    JSTIWindowCallback callback, void *context, char *error, size_t capacity) {
    if (!models || count == 0 || !callback || count > 10000) return jsti::fail("No transcription models or event callback.", error, capacity);
    std::vector<std::wstring> names(count);
    for (size_t i = 0; i < count; ++i) {
        if (!jsti::wide(models[i], names[i])) return jsti::fail("A model label is not valid UTF-8.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return jsti::fail("The desktop window is already running.", error, capacity);
        if (!state.configuredModelModes.empty() && state.configuredModelModes.size() != count) {
            return jsti::fail("The model mode catalogue does not match the supplied model labels.", error, capacity);
        }
        state.modelNames = std::move(names);
        state.modelModes = state.configuredModelModes.empty() ? std::vector<int>(count, 0) : state.configuredModelModes;
        for (int mode = 0; mode < 2; ++mode) {
            state.preferredModels[mode] = state.configuredPreferredModels[mode];
            if (state.preferredModels[mode] < 0) {
                const auto first = std::find(state.modelModes.begin(), state.modelModes.end(), mode);
                if (first != state.modelModes.end()) state.preferredModels[mode] = static_cast<int>(first - state.modelModes.begin());
            }
        }
        if (selected < 0 || static_cast<size_t>(selected) >= count) {
            selected = state.preferredModels[0] >= 0 ? state.preferredModels[0] : state.preferredModels[1];
        }
        state.activeMode = state.modelModes[selected];
        state.preferredModels[state.activeMode] = selected;
        state.filteredModels.clear();
        if (state.microphones.empty()) state.microphones.push_back({"", L"Default communications microphone"});
        state.running = true;
        state.recording = 0;
        state.posted = false;
        state.statusChanged = false;
        state.transcriptChanged = false;
        state.historyChanged = false;
        state.historySelectionProvided = false;
        state.pendingHistory.clear(); state.pendingHistorySelection.clear(); state.selectedHistoryID.clear();
        state.status.clear(); state.transcript.clear();
    }
    state.callback = callback; state.context = context;
    state.controls.clear();
    state.displayedHistory.clear();
    // The process may already have a manifest-defined awareness context.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItWindows";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    type.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    const ATOM registered = RegisterClassW(&type);
    HWND window = registered ? CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Just Speak to It — Windows Preview", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
        1100, hasModeChoice() ? 754 : 720, nullptr, nullptr, instance, nullptr) : nullptr;
    int outcome = 0;
    if (!window) outcome = jsti::fail(jsti::systemError("Creating native desktop window"), error, capacity);
    else {
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = window; }
        ShowWindow(window, SW_SHOWDEFAULT);
        UpdateWindow(window);
        emit(window, JSTI_EVENT_READY);
        if (!RegisterHotKey(window, hotkeyID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_SPACE)) {
            showFailure(window, "Ctrl+Alt+Space is unavailable. Another app may own it; use Record in this window.");
        }
        MSG message{};
        BOOL result;
        while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
            if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        }
        if (result < 0) {
            outcome = jsti::fail(jsti::systemError("Reading desktop messages"), error, capacity);
            DestroyWindow(window);
        }
    }
    if (state.font) { DeleteObject(state.font); state.font = nullptr; }
    state.controls.clear(); state.callback = nullptr; state.context = nullptr;
    state.displayedHistory.clear();
    if (registered) UnregisterClassW(type.lpszClassName, instance);
    { std::lock_guard<std::mutex> lock(state.mutex); state.running = false; state.window = nullptr; }
    return outcome;
}

int jsti_window_set_model_modes(const int *isLive, size_t count, int preferredBatch, int preferredLive) {
    if (count > 10000 || (count && !isLive)) return -1;
    try {
        std::vector<int> modes;
        if (count) modes.assign(isLive, isLive + count);
        if (std::any_of(modes.begin(), modes.end(), [](int mode) { return mode != 0 && mode != 1; })) return -1;
        const int preferred[] = {preferredBatch, preferredLive};
        for (int mode = 0; mode < 2; ++mode) {
            const int index = preferred[mode];
            if (index < -1 || (index >= 0 && (static_cast<size_t>(index) >= count || modes[index] != mode))) return -1;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return -1;
        state.configuredModelModes = std::move(modes);
        state.configuredPreferredModels[0] = preferredBatch;
        state.configuredPreferredModels[1] = preferredLive;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_microphones(const char *const *ids, const char *const *names, size_t count,
                                 const char *selectedID) {
    if (!ids || !names || !count || count > 512) return -1;
    try {
        std::vector<MicrophoneRow> devices;
        std::unordered_set<std::string> unique;
        bool found = false;
        const std::string selection = selectedID ? selectedID : "";
        for (size_t i = 0; i < count; ++i) {
            std::wstring identifier, name;
            if (!jsti::wide(ids[i], identifier) || !jsti::wide(names[i], name) || name.empty() ||
                identifier.size() > 4096 || name.size() > 4096 || !unique.insert(ids[i]).second) return -1;
            devices.push_back({ids[i], std::move(name)});
            if (devices.back().id == selection) found = true;
        }
        if (!found) return -1;
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return -1;
        state.microphones = std::move(devices);
        state.microphoneSelection = selection;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_update(const char *status, const char *transcript, int recording) {
    std::wstring wideStatus, wideTranscript;
    if ((status && !jsti::wide(status, wideStatus)) || (transcript && !jsti::wide(transcript, wideTranscript)) ||
        recording < -1 || recording > 2) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window) return -1;
    if (status) { state.status = std::move(wideStatus); state.statusChanged = true; }
    if (transcript) { state.transcript = std::move(wideTranscript); state.transcriptChanged = true; }
    if (recording >= 0) state.recording = recording;
    if (!state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

void jsti_window_request_close(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, WM_CLOSE, 0, 0);
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
            row.id = rows[i].id;
            if (!identifiers.insert(row.id).second) return -1;
            copied.push_back(std::move(row));
        }
        std::wstring checkedSelection;
        if (selectedID && !jsti::wide(selectedID, checkedSelection)) return -1;
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.pendingHistory = std::move(copied);
        state.historySelectionProvided = selectedID != nullptr;
        state.pendingHistorySelection = selectedID ? selectedID : "";
        state.historyChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) {
        return -1;
    }
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

int jsti_window_self_test(char *error, size_t errorCapacity) {
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("Window checks must run on the UI thread after READY.", error, errorCapacity);
    }
    const std::vector<HistoryRow> originalHistory = state.displayedHistory;
    const std::string originalSelection = selectedHistory(window);
    const std::vector<std::wstring> originalModelNames = state.modelNames;
    const std::vector<int> originalModelModes = state.modelModes;
    const int originalPreferredModels[] = {state.preferredModels[0], state.preferredModels[1]};
    const int originalMode = state.activeMode;
    const auto originalCallback = state.callback;
    void *const originalContext = state.context;
    RECT originalBounds{};
    GetWindowRect(window, &originalBounds);
    struct Event { int event = 0; std::string id; int model = -1; } observed;
    state.callback = [](int event, const char *id, int model, void *context) {
        auto &observed = *static_cast<Event *>(context);
        observed.event = event; observed.id = id ? id : ""; observed.model = model;
    };
    state.context = &observed;
    std::string failure;
    auto checkBounds = [&]() -> bool {
        SetWindowPos(window, nullptr, 0, 0, scale(window, 820), scale(window, hasModeChoice() ? 634 : 600),
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        layout(window);
        RECT client{};
        GetClientRect(window, &client);
        for (HWND control : state.controls) {
            if (!IsWindowVisible(control)) continue;
            RECT bounds{};
            GetWindowRect(control, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom ||
                bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
                failure = "A native control falls outside the minimum desktop window bounds.";
                return false;
            }
        }
        return true;
    };
    auto check = [&]() -> bool {
        // Deliberately interleaved global rows prove callbacks do not leak the
        // filtered combo index. These are never sent to the real Swift host.
        state.modelNames = {L"Batch Alpha", L"Live One", L"Batch Beta", L"Live Two"};
        state.modelModes = {0, 1, 0, 1};
        state.preferredModels[0] = 2;
        state.preferredModels[1] = 3;
        state.activeMode = 0;
        if (!populateModels(window) || !checkBounds() || selection(window) != 2 ||
            SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 2) {
            if (failure.empty()) failure = "Batch models did not retain their global identity.";
            return false;
        }
        auto changeMode = [&](int mode, int expected) {
            SendDlgItemMessageW(window, modeID, CB_SETCURSEL, mode, 0);
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(modeID, CBN_SELCHANGE), 0);
            return observed.event == JSTI_EVENT_MODEL_CHANGED && observed.model == expected &&
                selection(window) == expected &&
                (IsWindowEnabled(GetDlgItem(window, importID)) != FALSE) == (mode == 0);
        };
        SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
        if (observed.model != 0 || !changeMode(1, 3)) {
            failure = "Mode change did not restore its preferred global model."; return false;
        }
        SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
        if (observed.event != JSTI_EVENT_MODEL_CHANGED || observed.model != 1 ||
            !changeMode(0, 0) || !changeMode(1, 1)) {
            failure = "Mode-specific model selections were not preserved."; return false;
        }
        SetDlgItemTextW(window, keyID, L"synthetic-smoke-test-key");
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(saveID, BN_CLICKED), 0);
        if (observed.event != JSTI_EVENT_SAVE_CREDENTIAL || observed.model != 1) {
            failure = "Credential callback did not identify the global live model."; return false;
        }
        // Disabled Live import must never open a modal chooser or emit an event.
        const int previousEvent = observed.event;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(importID, BN_CLICKED), 0);
        if (observed.event != previousEvent) { failure = "Live mode admitted a batch import."; return false; }
        jsti_window_update(nullptr, nullptr, 1);
        applyUpdate(window);
        const bool recordingModesDisabled = !IsWindowEnabled(GetDlgItem(window, modeID)) &&
            !IsWindowEnabled(GetDlgItem(window, modelID));
        jsti_window_update(nullptr, nullptr, 0);
        applyUpdate(window);
        if (!recordingModesDisabled) { failure = "Recording allowed a model mode change."; return false; }
        const LRESULT originalMicrophone = SendDlgItemMessageW(window, microphoneID, CB_GETCURSEL, 0, 0);
        if (state.microphones.size() < 2) { failure = "Smoke test requires two synthetic microphone choices."; return false; }
        SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, 1, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(microphoneID, CBN_SELCHANGE), 0);
        const bool microphoneChanged = observed.event == JSTI_EVENT_MICROPHONE_CHANGED && observed.id == state.microphones[1].id;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
        const bool recordingSnapshot = observed.event == JSTI_EVENT_TOGGLE_RECORDING &&
            observed.id == state.microphones[1].id && observed.model == 1;
        SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, static_cast<WPARAM>(originalMicrophone), 0);
        if (!microphoneChanged || !recordingSnapshot) {
            failure = "Microphone selection and recording did not retain the exact selected device."; return false;
        }
        const JSTIHistoryRow first[] = {{"one", "First recording", "Completed"}, {"two", "Second recording", "Failed"}};
        if (jsti_window_set_history(first, 2, "two") != 0) { failure = "Initial history update failed."; return false; }
        applyUpdate(window);
        if (SendDlgItemMessageW(window, historyID, LB_GETCOUNT, 0, 0) != 2 || selectedHistory(window) != "two") {
            failure = "History rows or explicit selection were not rendered."; return false;
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
        const int controls[] = {retryID, exportID, openAudioID, copyID};
        const int events[] = {JSTI_EVENT_HISTORY_RETRY, JSTI_EVENT_HISTORY_EXPORT,
                              JSTI_EVENT_HISTORY_OPEN_AUDIO, JSTI_EVENT_COPY_TRANSCRIPT};
        for (size_t i = 0; i < 4; ++i) {
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(controls[i], BN_CLICKED), 0);
            if (observed.event != events[i] || observed.id != "one" || observed.model != 1) {
                failure = "A history action did not report its selected record ID."; return false;
            }
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
        state.modelModes.assign(state.modelNames.size(), 0);
        state.preferredModels[0] = 2;
        state.preferredModels[1] = -1;
        state.activeMode = 0;
        if (!populateModels(window) || !checkBounds() || IsWindowVisible(GetDlgItem(window, modeID)) ||
            IsWindowEnabled(GetDlgItem(window, modeID)) || !IsWindowEnabled(GetDlgItem(window, importID)) ||
            selection(window) != 2 || SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 4) {
            if (failure.empty()) failure = "The all-batch model catalogue lost legacy behaviour.";
            return false;
        }
        return jsti_settings_self_test(window, failure);
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { failure = "Window smoke test could not allocate its temporary state."; }
    state.modelNames = originalModelNames;
    state.modelModes = originalModelModes;
    state.preferredModels[0] = originalPreferredModels[0];
    state.preferredModels[1] = originalPreferredModels[1];
    state.activeMode = originalMode;
    if (!populateModels(window)) { passed = false; failure = "The model catalogue could not be restored after its smoke test."; }
    state.callback = originalCallback;
    state.context = originalContext;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.pendingHistory = originalHistory;
        state.pendingHistorySelection = originalSelection;
        state.historySelectionProvided = true;
        state.historyChanged = true;
    }
    applyUpdate(window);
    SetWindowPos(window, nullptr, originalBounds.left, originalBounds.top,
        originalBounds.right - originalBounds.left, originalBounds.bottom - originalBounds.top,
        SWP_NOZORDER | SWP_NOACTIVATE);
    return passed ? 0 : jsti::fail(failure, error, errorCapacity);
}

int jsti_window_save_snapshot(const char *path, char *error, size_t errorCapacity) {
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("The native snapshot must run on the UI thread after READY.", error, errorCapacity);
    }
    std::wstring filename;
    if (!jsti::wide(path, filename) || filename.empty()) {
        return jsti::fail("No valid native snapshot path supplied.", error, errorCapacity);
    }
    RECT bounds{};
    if (!GetClientRect(window, &bounds)) {
        return jsti::fail(jsti::systemError("Measuring the native window"), error, errorCapacity);
    }
    const LONG width = bounds.right - bounds.left;
    const LONG height = bounds.bottom - bounds.top;
    const int64_t pixelBytes = static_cast<int64_t>(width) * height * 4;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || pixelBytes > 64 * 1024 * 1024) {
        return jsti::fail("Native snapshot dimensions exceed the 64 MiB diagnostic limit.", error, errorCapacity);
    }
    // Only this app's own client DC is acquired. Never use GetDC(nullptr),
    // desktop BitBlt, or a caller-supplied window handle here.
    struct BitmapResources {
        HWND window;
        HDC source = nullptr;
        HDC memory = nullptr;
        HBITMAP bitmap = nullptr;
        HGDIOBJ previous = nullptr;
        explicit BitmapResources(HWND window) : window(window) {}
        ~BitmapResources() {
            if (previous && previous != HGDI_ERROR) SelectObject(memory, previous);
            if (bitmap) DeleteObject(bitmap);
            if (memory) DeleteDC(memory);
            if (source) ReleaseDC(window, source);
        }
    } resources(window);
    resources.source = GetDC(window);
    if (!resources.source) return jsti::fail(jsti::systemError("Opening the native window DC"), error, errorCapacity);
    resources.memory = CreateCompatibleDC(resources.source);
    if (!resources.memory) return jsti::fail(jsti::systemError("Creating the snapshot DC"), error, errorCapacity);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height; // Top-down DIB; no extra pixel-copy buffer.
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    info.bmiHeader.biSizeImage = static_cast<DWORD>(pixelBytes);
    void *pixels = nullptr;
    resources.bitmap = CreateDIBSection(resources.source, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!resources.bitmap || !pixels) {
        return jsti::fail(jsti::systemError("Allocating the native snapshot bitmap"), error, errorCapacity);
    }
    resources.previous = SelectObject(resources.memory, resources.bitmap);
    if (!resources.previous || resources.previous == HGDI_ERROR) {
        return jsti::fail(jsti::systemError("Selecting the snapshot bitmap"), error, errorCapacity);
    }
    PatBlt(resources.memory, 0, 0, width, height, WHITENESS);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    if (!PrintWindow(window, resources.memory, PW_CLIENTONLY)) {
        return jsti::fail(jsti::systemError("Rendering the native window snapshot"), error, errorCapacity);
    }
    // Native children render into the same app-owned client bitmap even when a
    // runner's window compositor is headless. This never samples desktop pixels.
    const int savedDC = SaveDC(resources.memory);
    RECT windowBounds{};
    POINT clientOrigin{};
    if (!savedDC || !GetWindowRect(window, &windowBounds) || !ClientToScreen(window, &clientOrigin) ||
        !SetViewportOrgEx(resources.memory, windowBounds.left - clientOrigin.x,
            windowBounds.top - clientOrigin.y, nullptr)) {
        if (savedDC) RestoreDC(resources.memory, savedDC);
        return jsti::fail(jsti::systemError("Aligning the native client snapshot"), error, errorCapacity);
    }
    SendMessageW(window, WM_PRINT, reinterpret_cast<WPARAM>(resources.memory),
        PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND);
    RestoreDC(resources.memory, savedDC);
    if (!GdiFlush()) return jsti::fail(jsti::systemError("Completing native snapshot drawing"), error, errorCapacity);
    const auto *values = static_cast<const uint32_t *>(pixels);
    const uint32_t first = values[0] & 0x00FFFFFF;
    bool varied = false;
    for (size_t i = 1; i < static_cast<size_t>(pixelBytes / 4); ++i) {
        if ((values[i] & 0x00FFFFFF) != first) { varied = true; break; }
    }
    if (!varied) return jsti::fail("Windows returned a blank native window snapshot.", error, errorCapacity);
    BITMAPFILEHEADER header{};
    header.bfType = 0x4D42;
    header.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    header.bfSize = header.bfOffBits + static_cast<DWORD>(pixelBytes);
    jsti::Handle file;
    file.value = CreateFileW(filename.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) {
        return jsti::fail(jsti::systemError("Creating the native snapshot file"), error, errorCapacity);
    }
    auto write = [&](const void *bytes, DWORD count) {
        DWORD written = 0;
        return WriteFile(file.value, bytes, count, &written, nullptr) && written == count;
    };
    if (!write(&header, sizeof(header)) || !write(&info.bmiHeader, sizeof(info.bmiHeader)) ||
        !write(pixels, static_cast<DWORD>(pixelBytes)) || !FlushFileBuffers(file.value)) {
        return jsti::fail(jsti::systemError("Writing the native snapshot file"), error, errorCapacity);
    }
    return 0;
}
