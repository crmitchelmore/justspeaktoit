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
bool jsti_profiles_self_test(HWND owner, std::string &error);
void jsti_show_profiles(HWND owner);
void jsti_cancel_profiles_request();
bool jsti_text_output_available();
void jsti_show_text_output(HWND owner);
bool jsti_text_output_settings_self_test(HWND owner, int button, void (*setRecording)(HWND, int),
                                         bool (*recordingBlocked)(HWND, void *), void *context, std::string &error);
bool jsti_hotkey_available();
std::wstring jsti_hotkey_label();
bool jsti_hotkey_start(HWND window, std::string &failure);
void jsti_hotkey_stop(HWND window);
bool jsti_hotkey_message(HWND window, UINT message, WPARAM wparam);
void jsti_show_hotkey_settings(HWND owner);
bool jsti_hotkey_self_test(HWND owner, int (*observe)(void *), void *context, std::string &error);
bool jsti_voice_output_available();
void jsti_show_voice_settings(HWND owner);
bool jsti_voice_settings_self_test(HWND owner, std::string &error);
bool jsti_local_models_available();
std::wstring jsti_local_models_summary();
void jsti_show_local_models(HWND owner);
bool jsti_local_models_self_test(HWND owner, std::string &error);
bool jsti_cloud_sync_available();
void jsti_show_cloud_sync_settings(HWND owner);
bool jsti_cloud_sync_settings_self_test(HWND owner, std::string &error);
int jsti_window_recording_state();

namespace {
constexpr UINT updateMessage = WM_APP + 1;
constexpr UINT profilesMessage = WM_APP + 17;
constexpr int hotkeyID = 1;
constexpr int modelRefreshID = 140;
constexpr int modelStatusID = 141;
enum Control {
    modelID = 100, keyID, saveID, recordID, importID, copyID, transcriptID, statusID,
    historyID, historyDetailID, retryID, exportID, openAudioID, processingID, microphoneID, modeID,
    searchID, clearSearchID, variantID, profilesID = 150
};
constexpr int searchLabelID = 96;
constexpr int variantLabelID = 97;
// Native History playback controls. Explicit reserved identifiers, outside the
// implicit Control enumeration, so existing control identities never shift.
constexpr int playbackLabelID = 98;
constexpr int playPauseID = 160;
constexpr int stopPlaybackID = 161;
constexpr int playbackTimeID = 162;
// Opens the native Text output dialog directly; it emits no window event.
constexpr int textOutputID = 170;
// Opens the native Shortcut dialog directly; it emits no window event.
constexpr int shortcutID = 171;
constexpr int transcriptLabelID = 92;
// Read aloud emits an event; Voice… opens the native Voice output dialog.
constexpr int readAloudID = 172;
constexpr int voiceSettingsID = 173;
// Settings menu commands. They open the same dialogs as their buttons; the
// automation item emits AUTOMATION_TOGGLED with the requested state.
constexpr int menuShortcutID = 180, menuTextOutputID = 181, menuVoiceID = 182, menuPostProcessingID = 183,
    menuAutomationID = 184, menuCloudSyncID = 185, menuLocalModelsID = 186;
// The Source picker (Remote/Local) and the Local models dialog button, which
// takes the place of Refresh models while the Local source is selected.
constexpr int sourceLabelID = 89;
constexpr int localModelsID = 174;
constexpr int sourceID = 175;
// Model modes: bit 0 is live, bit 1 is local (on-device).
constexpr int modeCount = 4;
constexpr int playbackIdle = 0, playbackPreparing = 1, playbackPlaying = 2, playbackPaused = 3;
const wchar_t *const playbackIdleText = L"00:00.00 / --:--";
struct HistoryRow {
    std::string id;
    std::wstring title;
    std::wstring detail;
};
struct HistoryPresentation {
    std::string record;
    int variant = -1;
    bool switchable = false;
    std::wstring transcript;
    std::wstring status;
};
struct MicrophoneRow { std::string id; std::wstring name; };
struct ModelRow { std::string id; std::wstring name; int mode = 0; int order = -1; };
struct WindowState {
    std::mutex mutex;
    HWND window = nullptr;
    bool running = false;
    bool automationEnabled = false, automationChanged = false;
    bool posted = false;
    bool statusChanged = false;
    bool transcriptChanged = false;
    bool historyChanged = false;
    bool historySelectionProvided = false;
    uint64_t historyInteractionRevision = 0;
    uint64_t pendingHistoryRevision = 0;
    bool variantChanged = false;
    bool presentationChanged = false;
    HistoryPresentation pendingPresentation;
    bool microphonesChanged = false;
    std::vector<MicrophoneRow> pendingMicrophones;
    std::wstring microphoneError;
    bool modelsChanged = false;
    bool modelsRefreshing = false;
    std::wstring modelStatus;
    std::vector<ModelRow> pendingModels;
    std::vector<std::pair<std::string, int>> knownModelIdentities;
    std::string pendingVariantRecord;
    int pendingVariant = -1;
    bool pendingVariantSwitchable = false;
    bool playbackChanged = false;
    std::string pendingPlaybackRecord;
    int pendingPlaybackState = playbackIdle;
    std::wstring pendingPlaybackText;
    int recording = 0;
    std::wstring status;
    std::wstring transcript;
    std::vector<MicrophoneRow> microphones;
    std::string microphoneSelection;
    std::vector<int> configuredModelModes;
    int configuredPreferredModels[3] = {-1, -1, -1}; // Global remote batch, remote live and local batch rows.
    std::vector<HistoryRow> pendingHistory;
    std::string pendingHistorySelection;
    std::string selectedHistoryID;
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    // Only accessed by the UI thread. Pending snapshots above use mutex.
    std::vector<HistoryRow> displayedHistory;
    int displayedVariant = -1;
    bool variantSwitchable = false;
    bool historyPresentationReady = false;
    int requestedVariant = -1;
    int displayedPlayback = playbackIdle;
    bool suppressSearchEvents = false;
    std::vector<std::wstring> modelNames;
    std::vector<int> modelModes;
    std::vector<int> modelOrder;
    std::vector<int> filteredModels;
    int preferredModels[modeCount] = {-1, -1, -1, -1};
    int activeMode = 0;
    std::wstring remoteModelStatus;
} state;

int selection(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    return index == CB_ERR || static_cast<size_t>(index) >= state.filteredModels.size()
        ? -1 : state.filteredModels[static_cast<size_t>(index)];
}

int activeSource() { return state.activeMode / 2; }

bool hasModeChoice() {
    const int source = activeSource() * 2;
    return state.preferredModels[source] >= 0 && state.preferredModels[source + 1] >= 0;
}

bool hasSourceChoice() {
    return (state.preferredModels[0] >= 0 || state.preferredModels[1] >= 0) &&
        (state.preferredModels[2] >= 0 || state.preferredModels[3] >= 0);
}

bool liveSelection(HWND window) {
    const int selected = selection(window);
    return selected >= 0 && static_cast<size_t>(selected) < state.modelModes.size() &&
        state.modelModes[selected] % 2 == 1;
}

// Remote shows OpenRouter discovery and Refresh models; Local shows the
// on-device runtime and the Local models dialog.
void updateSourceControls(HWND window) {
    const bool local = activeSource() == 1;
    ShowWindow(GetDlgItem(window, modelRefreshID), local ? SW_HIDE : SW_SHOW);
    ShowWindow(GetDlgItem(window, localModelsID), local ? SW_SHOW : SW_HIDE);
    const std::wstring text = local ? jsti_local_models_summary() : state.remoteModelStatus;
    wchar_t shown[1100] = {};
    GetDlgItemTextW(window, modelStatusID, shown, 1100);
    if (text != shown) SetDlgItemTextW(window, modelStatusID, text.c_str());
}

void updateModelAvailability(HWND window, int recording) {
    EnableWindow(GetDlgItem(window, modeID), recording == 0 && hasModeChoice());
    EnableWindow(GetDlgItem(window, sourceID), recording == 0 && hasSourceChoice());
    EnableWindow(GetDlgItem(window, localModelsID), recording == 0 && jsti_local_models_available());
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
    std::vector<size_t> visible;
    for (size_t index = 0; index < state.modelNames.size(); ++index) {
        if (state.modelModes[index] != state.activeMode) continue;
        const int rank = index < state.modelOrder.size() ? state.modelOrder[index] : static_cast<int>(index);
        if (rank >= 0 || static_cast<int>(index) == state.preferredModels[state.activeMode]) visible.push_back(index);
    }
    auto rank = [](size_t index) {
        const int value = index < state.modelOrder.size() ? state.modelOrder[index] : static_cast<int>(index);
        return value < 0 ? (std::numeric_limits<int>::max)() : value;
    };
    std::stable_sort(visible.begin(), visible.end(), [&](size_t left, size_t right) { return rank(left) < rank(right); });
    for (const size_t index : visible) {
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
    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, state.activeMode % 2, 0);
    const bool sources = hasSourceChoice();
    ShowWindow(GetDlgItem(window, sourceID), sources ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(window, sourceLabelID), sources ? SW_SHOW : SW_HIDE);
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
    const wchar_t *label = activeSource() == 1 ? L"On-device &transcription model"
        : (!choice && state.activeMode == 1 ? L"Live &transcription model" : L"&Transcription model");
    SetDlgItemTextW(window, 90, label);
    updateSourceControls(window);
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    updateModelAvailability(window, recording);
    return success;
}

void updateModelLayout(HWND window);

bool applyModelRows(HWND window, const std::vector<ModelRow> &rows) {
    if (rows.empty()) return true;
    bool changed = rows.size() != state.modelNames.size();
    for (size_t index = 0; !changed && index < rows.size(); ++index) {
        changed = rows[index].name != state.modelNames[index] || rows[index].mode != state.modelModes[index] ||
            index >= state.modelOrder.size() || rows[index].order != state.modelOrder[index];
    }
    if (!changed) return true;
    const int selected = selection(window);
    if (selected >= 0) state.preferredModels[state.activeMode] = selected;
    const bool hadModeChoice = hasModeChoice() || hasSourceChoice();
    int oldPreferred[modeCount];
    std::copy(std::begin(state.preferredModels), std::end(state.preferredModels), oldPreferred);
    auto oldNames = state.modelNames;
    auto oldModes = state.modelModes;
    auto oldOrder = state.modelOrder;
    std::vector<std::wstring> names;
    std::vector<int> modes, order;
    for (const auto &row : rows) {
        names.push_back(row.name);
        modes.push_back(row.mode);
        order.push_back(row.order);
    }
    state.modelNames = std::move(names); state.modelModes = std::move(modes); state.modelOrder = std::move(order);
    for (size_t index = 0; index < rows.size(); ++index) {
        if (rows[index].order >= 0 && state.preferredModels[rows[index].mode] < 0) {
            state.preferredModels[rows[index].mode] = static_cast<int>(index);
        }
    }
    if (populateModels(window)) {
        if (hadModeChoice != (hasModeChoice() || hasSourceChoice())) updateModelLayout(window);
        return true;
    }
    std::copy(std::begin(oldPreferred), std::end(oldPreferred), state.preferredModels);
    state.modelNames = std::move(oldNames); state.modelModes = std::move(oldModes); state.modelOrder = std::move(oldOrder);
    populateModels(window);
    return false;
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
    // Registered hotkeys still reach a disabled owner through a modal loop.
    // Child controls keep their enabled flags, so check the owner as well.
    if (!IsWindowEnabled(window)) return;
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

bool searching(HWND window) { return GetWindowTextLengthW(GetDlgItem(window, searchID)) > 0; }

// The variant control never infers a version: it shows only what the host
// reported for the selected record, and a user choice is echoed back by event.
void applyVariant(HWND window, int selected, bool switchable, int recording) {
    state.displayedVariant = selected == 0 || selected == 1 ? selected : -1;
    state.variantSwitchable = switchable && state.displayedVariant >= 0;
    SendDlgItemMessageW(window, variantID, CB_SETCURSEL,
        state.displayedVariant < 0 ? static_cast<WPARAM>(-1) : static_cast<WPARAM>(state.displayedVariant), 0);
    EnableWindow(GetDlgItem(window, variantID), state.variantSwitchable && recording == 0);
}

// Play/Pause is available for a selected idle record, or whenever a playback
// is active so it can always be paused; Stop only while a playback is active.
// The label follows the state the host acknowledged, never a click.
void updatePlaybackControls(HWND window, bool selected, int recording) {
    const bool active = state.displayedPlayback != playbackIdle;
    SetDlgItemTextW(window, playPauseID,
        state.displayedPlayback == playbackPreparing || state.displayedPlayback == playbackPlaying ? L"Pause" : L"Play");
    EnableWindow(GetDlgItem(window, playPauseID), (selected && recording == 0) || active);
    EnableWindow(GetDlgItem(window, stopPlaybackID), active);
}

// The playback display never infers progress: it shows only what the host
// reported for the selected record, and controls are echoed back by event.
void applyPlayback(HWND window, int playback, const std::wstring &text, bool selected, int recording) {
    state.displayedPlayback = playback >= playbackIdle && playback <= playbackPaused ? playback : playbackIdle;
    SetDlgItemTextW(window, playbackTimeID, text.empty() ? playbackIdleText : text.c_str());
    updatePlaybackControls(window, selected, recording);
}

void updateHistoryControls(HWND window, int recording) {
    const LRESULT index = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
    const bool selected = index != LB_ERR && static_cast<size_t>(index) < state.displayedHistory.size();
    const bool filtering = searching(window);
    if (!selected && state.displayedPlayback != playbackIdle) applyPlayback(window, playbackIdle, L"", false, recording);
    else updatePlaybackControls(window, selected, recording);
    SetDlgItemTextW(window, historyDetailID, selected ? state.displayedHistory[static_cast<size_t>(index)].detail.c_str()
        : (state.displayedHistory.empty()
            ? (filtering ? L"No saved recordings match this search." : L"Your saved recordings will appear here.")
            : L"Select a saved recording."));
    EnableWindow(GetDlgItem(window, historyID), recording == 0);
    EnableWindow(GetDlgItem(window, searchID), recording == 0);
    EnableWindow(GetDlgItem(window, clearSearchID), recording == 0 && filtering);
    for (int id : {retryID, openAudioID}) EnableWindow(GetDlgItem(window, id), selected && recording == 0);
    EnableWindow(GetDlgItem(window, exportID), selected && recording == 0 && state.historyPresentationReady);
    EnableWindow(GetDlgItem(window, readAloudID), selected && recording == 0 && state.historyPresentationReady &&
        jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, voiceSettingsID), recording == 0 && jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, copyID), state.historyPresentationReady && (!selected || recording == 0));
    if (!selected) applyVariant(window, -1, false, recording);
    else EnableWindow(GetDlgItem(window, variantID), state.variantSwitchable && recording == 0);
}

// Clear stale text synchronously, before the async host sees this UI event.
void invalidateHistoryPresentation(HWND window, bool resetVersion) {
    state.historyPresentationReady = false;
    if (resetVersion) state.requestedVariant = -1;
    SetDlgItemTextW(window, transcriptID, L"");
    SetDlgItemTextW(window, statusID, selectedHistory(window).empty()
        ? L"Select a saved recording." : L"Loading saved transcript…");
    EnableWindow(GetDlgItem(window, copyID), FALSE);
    EnableWindow(GetDlgItem(window, exportID), FALSE);
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
    if (state.suppressSearchEvents) return;
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    EnableWindow(GetDlgItem(window, clearSearchID), recording == 0 && searching(window));
    const std::string query = jsti::utf8(searchText(window));
    emit(window, JSTI_EVENT_HISTORY_SEARCH, query.c_str());
}

void clearSearch(HWND window) {
    if (!searching(window)) return;
    state.suppressSearchEvents = true;
    SetDlgItemTextW(window, searchID, L"");
    state.suppressSearchEvents = false;
    searchChanged(window);
    if (GetActiveWindow() == window) SetFocus(GetDlgItem(window, searchID));
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

// The client layout needs 684 DIPs of window height below the Settings menu bar.
int minimumWindowHeight(HWND window) {
    const int menu = GetMenu(window) ? GetSystemMetricsForDpi(SM_CYMENU, GetDpiForWindow(window)) : 0;
    return scale(window, 724) + menu;
}

// Dialog commands follow their buttons' idle rules; automation can change at any time.
void updateSettingsMenu(HWND window, int recording) {
    const HMENU menu = GetMenu(window);
    if (!menu) return;
    auto enable = [&](int id, bool enabled) { EnableMenuItem(menu, id, MF_BYCOMMAND | (enabled ? MF_ENABLED : MF_GRAYED)); };
    enable(menuShortcutID, recording == 0 && jsti_hotkey_available());
    enable(menuTextOutputID, recording == 0 && jsti_text_output_available());
    enable(menuVoiceID, recording == 0 && jsti_voice_output_available());
    enable(menuPostProcessingID, recording == 0 && jsti_postprocessing_available());
    enable(menuLocalModelsID, recording == 0 && jsti_local_models_available());
    enable(menuCloudSyncID, recording == 0 && jsti_cloud_sync_available());
    bool automation;
    { std::lock_guard<std::mutex> lock(state.mutex); automation = state.automationEnabled; }
    CheckMenuItem(menu, menuAutomationID, MF_BYCOMMAND | (automation ? MF_CHECKED : MF_UNCHECKED));
}

HMENU createSettingsMenu() {
    HMENU bar = CreateMenu();
    HMENU settings = CreatePopupMenu();
    if (!bar || !settings ||
        !AppendMenuW(settings, MF_STRING, menuShortcutID, L"&Keyboard shortcut\u2026") ||
        !AppendMenuW(settings, MF_STRING, menuTextOutputID, L"&Text output\u2026") ||
        !AppendMenuW(settings, MF_STRING, menuVoiceID, L"&Voice\u2026") ||
        !AppendMenuW(settings, MF_STRING, menuPostProcessingID, L"&Post-processing\u2026") ||
        !AppendMenuW(settings, MF_STRING, menuLocalModelsID, L"&Local models\u2026") ||
        !AppendMenuW(settings, MF_STRING, menuCloudSyncID, L"i&Cloud sync\u2026") ||
        !AppendMenuW(settings, MF_SEPARATOR, 0, nullptr) ||
        !AppendMenuW(settings, MF_STRING, menuAutomationID, L"Allow &automation (speak command)") ||
        !AppendMenuW(bar, MF_POPUP, reinterpret_cast<UINT_PTR>(settings), L"Setti&ngs")) {
        if (settings) DestroyMenu(settings);
        if (bar) DestroyMenu(bar);
        return nullptr;
    }
    return bar;
}

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
    // The App profiles action always occupies the top row, beside Source.
    // Mode has its own row below, so the choice reads Source, then Mode.
    const int selectorRow = row + scale(window, 6);
    const int modelTop = margin + row + selectorRow;
    const int profilesWidth = scale(window, 118);
    const int shortcutWidth = scale(window, 148);
    const int selectorWidth = width - scale(window, 70) - profilesWidth - shortcutWidth - 2 * gap;
    move(sourceLabelID, contentLeft, margin + scale(window, 3), scale(window, 64), scale(window, 22));
    move(sourceID, contentLeft + scale(window, 70), margin, selectorWidth, scale(window, 160));
    move(95, contentLeft, margin + selectorRow + scale(window, 3), scale(window, 64), scale(window, 22));
    move(modeID, contentLeft + scale(window, 70), margin + selectorRow, selectorWidth, scale(window, 160));
    move(shortcutID, contentLeft + width - profilesWidth - gap - shortcutWidth, margin, shortcutWidth, row);
    move(profilesID, contentLeft + width - profilesWidth, margin, profilesWidth, row);
    move(90, contentLeft, modelTop, width, scale(window, 22));
    const int settingsWidth = scale(window, 148);
    move(modelID, contentLeft, modelTop + scale(window, 26), width - settingsWidth - gap, scale(window, 260));
    move(processingID, contentLeft + width - settingsWidth, modelTop + scale(window, 26), settingsWidth, row);
    const int discoveryTop = modelTop + scale(window, 70);
    move(modelStatusID, contentLeft, discoveryTop, width - settingsWidth - gap, scale(window, 46));
    move(modelRefreshID, contentLeft + width - settingsWidth, discoveryTop, settingsWidth, row);
    move(localModelsID, contentLeft + width - settingsWidth, discoveryTop, settingsWidth, row);
    move(91, contentLeft, modelTop + scale(window, 120), width, scale(window, 22));
    const int keyTop = modelTop + scale(window, 146);
    move(keyID, contentLeft, keyTop, width - saveWidth - gap, row);
    move(saveID, contentLeft + width - saveWidth, keyTop, saveWidth, row);
    const int microphoneTop = keyTop + row + gap;
    move(94, contentLeft, microphoneTop, width, scale(window, 22));
    move(microphoneID, contentLeft, microphoneTop + scale(window, 26), width - settingsWidth - gap, scale(window, 260));
    move(textOutputID, contentLeft + width - settingsWidth, microphoneTop + scale(window, 26), settingsWidth, row);
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
    move(searchLabelID, margin, margin, historyWidth, scale(window, 22));
    const int searchTop = margin + scale(window, 26);
    const int clearWidth = scale(window, 64);
    move(searchID, margin, searchTop, historyWidth - clearWidth - gap, row);
    move(clearSearchID, margin + historyWidth - clearWidth, searchTop, clearWidth, row);
    const int historyLabelTop = searchTop + row + gap;
    move(93, margin, historyLabelTop, historyWidth, scale(window, 22));
    const int historyTop = historyLabelTop + scale(window, 26);
    const int detailHeight = scale(window, 72);
    // Below the list: detail, version label+combo, two action rows, the
    // playback label/time row and the Play/Pause + Stop row.
    const int historyHeight = std::max(scale(window, 120), static_cast<int>(bounds.bottom) - historyTop -
        detailHeight - scale(window, 52) - 4 * row - 5 * gap - margin);
    move(historyID, margin, historyTop, historyWidth, historyHeight);
    const int detailTop = historyTop + historyHeight + gap;
    move(historyDetailID, margin, detailTop, historyWidth, detailHeight);
    const int variantLabelTop = detailTop + detailHeight + gap;
    move(variantLabelID, margin, variantLabelTop, historyWidth, scale(window, 22));
    move(variantID, margin, variantLabelTop + scale(window, 26), historyWidth, scale(window, 120));
    const int buttonsTop = variantLabelTop + scale(window, 26) + row + gap;
    const int buttonWidth = (historyWidth - gap) / 2;
    move(retryID, margin, buttonsTop, buttonWidth, row);
    move(exportID, margin + buttonWidth + gap, buttonsTop, buttonWidth, row);
    move(openAudioID, margin, buttonsTop + row + gap, buttonWidth, row);
    move(readAloudID, margin + buttonWidth + gap, buttonsTop + row + gap, buttonWidth, row);
    const int playbackLabelTop = buttonsTop + 2 * (row + gap);
    const int playbackLabelWidth = scale(window, 84);
    move(playbackLabelID, margin, playbackLabelTop, playbackLabelWidth, scale(window, 22));
    move(playbackTimeID, margin + playbackLabelWidth, playbackLabelTop, historyWidth - playbackLabelWidth, scale(window, 22));
    const int playbackTop = playbackLabelTop + scale(window, 26);
    const int playbackWidth = (historyWidth - 2 * gap) / 3;
    move(playPauseID, margin, playbackTop, playbackWidth, row);
    move(stopPlaybackID, margin + playbackWidth + gap, playbackTop, playbackWidth, row);
    move(voiceSettingsID, margin + 2 * (playbackWidth + gap), playbackTop, historyWidth - 2 * (playbackWidth + gap), row);
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

void updateModelLayout(HWND window) {
    RECT bounds{};
    GetWindowRect(window, &bounds);
    const int minimumHeight = minimumWindowHeight(window);
    if (bounds.bottom - bounds.top < minimumHeight) {
        SetWindowPos(window, nullptr, 0, 0, bounds.right - bounds.left, minimumHeight,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    layout(window);
}

bool createControls(HWND window) {
    auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int identifier) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 || wcscmp(kind, L"LISTBOX") == 0 ? WS_EX_CLIENTEDGE : 0, kind, label,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(identifier)), GetModuleHandleW(nullptr), nullptr);
        if (control) state.controls.push_back(control);
        return control != nullptr;
    };
    // Each STATIC label immediately precedes its control so assistive
    // technology and Alt mnemonics resolve the intended target.
    const bool okay = add(L"STATIC", L"&Find in history", 0, searchLabelID) &&
        add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, searchID) &&
        add(L"BUTTON", L"C&lear", BS_PUSHBUTTON | WS_TABSTOP, clearSearchID) &&
        add(L"STATIC", L"&History", 0, 93) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, historyID) &&
        add(L"STATIC", L"Your saved recordings will appear here.", SS_LEFT, historyDetailID) &&
        add(L"STATIC", L"Transcript &version", 0, variantLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, variantID) &&
        add(L"BUTTON", L"Retr&y", BS_PUSHBUTTON | WS_TABSTOP, retryID) &&
        add(L"BUTTON", L"&Export text", BS_PUSHBUTTON | WS_TABSTOP, exportID) &&
        add(L"BUTTON", L"&Open audio", BS_PUSHBUTTON | WS_TABSTOP, openAudioID) &&
        add(L"BUTTON", L"Rea&d aloud", BS_PUSHBUTTON | WS_TABSTOP, readAloudID) &&
        // The label carries the mnemonic and precedes Play/Pause, so Alt+B
        // and assistive technology reach the playback controls.
        add(L"STATIC", L"Play&back", 0, playbackLabelID) &&
        add(L"STATIC", playbackIdleText, SS_RIGHT, playbackTimeID) &&
        add(L"BUTTON", L"Play", BS_PUSHBUTTON | WS_TABSTOP, playPauseID) &&
        add(L"BUTTON", L"Stop", BS_PUSHBUTTON | WS_TABSTOP, stopPlaybackID) &&
        add(L"BUTTON", L"Voice…", BS_PUSHBUTTON | WS_TABSTOP, voiceSettingsID) &&
        add(L"BUTTON", L"App &profiles", BS_PUSHBUTTON | WS_TABSTOP, profilesID) &&
        add(L"STATIC", L"&Source", 0, sourceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, sourceID) &&
        add(L"STATIC", L"&Mode", 0, 95) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, modeID) &&
        add(L"BUTTON", L"&Keyboard shortcut…", BS_PUSHBUTTON | WS_TABSTOP, shortcutID) &&
        add(L"STATIC", L"&Transcription model", 0, 90) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"BUTTON", L"&Post-processing…", BS_PUSHBUTTON | WS_TABSTOP, processingID) &&
        add(L"STATIC", L"OpenRouter discovery not loaded.", SS_LEFT, modelStatusID) &&
        add(L"BUTTON", L"Refresh &models", BS_PUSHBUTTON | WS_TABSTOP, modelRefreshID) &&
        add(L"BUTTON", L"Local mo&dels\u2026", BS_PUSHBUTTON | WS_TABSTOP, localModelsID) &&
        add(L"STATIC", L"&API key (Windows Credential Manager)", 0, 91) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"STATIC", L"&Microphone", 0, 94) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, microphoneID) &&
        add(L"BUTTON", L"Text o&utput…", BS_PUSHBUTTON | WS_TABSTOP, textOutputID) &&
        add(L"BUTTON", L"&Record", BS_PUSHBUTTON | WS_TABSTOP, recordID) &&
        add(L"BUTTON", L"&Import audio", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"BUTTON", L"&Copy transcript", BS_PUSHBUTTON | WS_TABSTOP, copyID) &&
        add(L"STATIC", jsti_hotkey_label().c_str(), 0, transcriptLabelID) &&
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
    SendDlgItemMessageW(window, searchID, EM_LIMITTEXT, 512, 0);
    SendDlgItemMessageW(window, transcriptID, EM_LIMITTEXT, 4 * 1024 * 1024, 0);
    refreshFont(window);
    if (SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Remote (API providers)")) < 0 ||
        SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Local (on this PC)")) < 0 ||
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Batch")) < 0 ||
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Live")) < 0 ||
        SendDlgItemMessageW(window, variantID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Processed transcript")) < 0 ||
        SendDlgItemMessageW(window, variantID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Original transcript")) < 0 ||
        !populateModels(window)) return false;
    applyVariant(window, -1, false, 0);
    updateHistoryControls(window, 0);
    EnableWindow(GetDlgItem(window, processingID), jsti_postprocessing_available());
    EnableWindow(GetDlgItem(window, textOutputID), jsti_text_output_available());
    EnableWindow(GetDlgItem(window, shortcutID), jsti_hotkey_available());
    std::wstring modelStatus;
    bool refreshing;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelStatus = state.modelStatus;
        refreshing = state.modelsRefreshing;
    }
    state.remoteModelStatus = modelStatus;
    updateSourceControls(window);
    EnableWindow(GetDlgItem(window, modelRefreshID), !refreshing);
    return okay;
}


// UI thread only. The persisted choice is an opaque ID, never a row index.
// Missing devices retain that choice; a programmatic rebuild emits no event.
bool populateMicrophones(HWND window) {
    HWND combo = GetDlgItem(window, microphoneID);
    SendMessageW(combo, WM_SETREDRAW, FALSE, 0);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    LRESULT selected = CB_ERR;
    bool okay = true;
    for (size_t index = 0; index < state.microphones.size(); ++index) {
        const auto &row = state.microphones[index];
        const LRESULT added = SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) { okay = false; break; }
        if (row.id == state.microphoneSelection) selected = added;
    }
    SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(selected), 0);
    SendMessageW(combo, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(combo, nullptr, TRUE);
    return okay && selected != CB_ERR;
}

bool applyMicrophones(HWND window, std::vector<MicrophoneRow> rows) {
    const auto selected = std::find_if(rows.begin(), rows.end(), [](const auto &row) {
        return row.id == state.microphoneSelection;
    });
    if (selected == rows.end()) {
        const auto previous = std::find_if(state.microphones.begin(), state.microphones.end(), [](const auto &row) {
            return row.id == state.microphoneSelection;
        });
        std::wstring name = previous == state.microphones.end() ? L"Previously selected microphone" : previous->name;
        const std::wstring defaultMarker = L" (system default)";
        const size_t marker = name.find(defaultMarker);
        if (marker != std::wstring::npos) name.erase(marker, defaultMarker.size());
        const std::wstring suffix = L" (unavailable)";
        if (name.size() < suffix.size() || name.substr(name.size() - suffix.size()) != suffix) name += suffix;
        rows.push_back({state.microphoneSelection, std::move(name)});
    }
    auto previous = std::move(state.microphones);
    state.microphones = std::move(rows);
    if (populateMicrophones(window)) return true;
    state.microphones = std::move(previous);
    populateMicrophones(window);
    return false;
}

void applyUpdate(HWND window) {
    std::wstring status, transcript;
    bool microphonesChanged;
    std::vector<MicrophoneRow> microphones;
    std::wstring microphoneError;
    bool statusChanged, transcriptChanged, historyChanged, variantChanged, variantSwitchable;
    bool modelsChanged, modelsRefreshing;
    std::vector<ModelRow> models;
    std::wstring modelStatus;
    std::vector<HistoryRow> history;
    std::string historySelection, variantRecord, playbackRecord;
    std::wstring playbackText;
    int recording, variant, playback;
    bool playbackChanged, presentationChanged, explicitHistorySelection = false;
    HistoryPresentation presentation;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        status.swap(state.status); transcript.swap(state.transcript);
        presentationChanged = state.presentationChanged;
        if (presentationChanged) presentation = std::move(state.pendingPresentation);
        state.presentationChanged = false;
        playbackChanged = state.playbackChanged;
        playbackRecord = state.pendingPlaybackRecord;
        playback = state.pendingPlaybackState;
        playbackText = state.pendingPlaybackText;
        state.playbackChanged = false;
        modelsChanged = state.modelsChanged;
        modelsRefreshing = state.modelsRefreshing;
        if (modelsChanged) { models = std::move(state.pendingModels); modelStatus = state.modelStatus; }
        state.modelsChanged = false;
        statusChanged = state.statusChanged; transcriptChanged = state.transcriptChanged;
        state.statusChanged = false; state.transcriptChanged = false;
        historyChanged = state.historyChanged;
        if (historyChanged) {
            history = std::move(state.pendingHistory);
            explicitHistorySelection = state.historySelectionProvided &&
                state.pendingHistoryRevision == state.historyInteractionRevision;
            historySelection = explicitHistorySelection ? state.pendingHistorySelection : state.selectedHistoryID;
            state.historyChanged = false;
        }
        variantChanged = state.variantChanged;
        variantRecord = state.pendingVariantRecord;
        variant = state.pendingVariant;
        variantSwitchable = state.pendingVariantSwitchable;
        state.variantChanged = false;
        state.posted = false;
        recording = state.recording;
        microphonesChanged = state.microphonesChanged && recording == 0;
        if (microphonesChanged) {
            microphones = std::move(state.pendingMicrophones);
            microphoneError = state.microphoneError;
            state.microphonesChanged = false;
        }
    }
    if (microphonesChanged) {
        if (!microphones.empty() && !applyMicrophones(window, std::move(microphones))) {
            microphoneError = L"Could not display updated microphone choices";
        }
        const std::wstring label = microphoneError.empty() ? L"&Microphone" : L"&Microphone — list refresh unavailable";
        SetDlgItemTextW(window, 94, label.c_str());
    }
    if (modelsChanged) {
        if (!applyModelRows(window, models)) modelStatus = L"Could not display refreshed models. Previous selection retained.";
        state.remoteModelStatus = modelStatus;
        EnableWindow(GetDlgItem(window, modelRefreshID), !modelsRefreshing);
    }
    updateSourceControls(window);
    if (statusChanged) SetDlgItemTextW(window, statusID, status.c_str());

    SetDlgItemTextW(window, recordID, recording == 1 ? L"&Stop recording" : (recording == 2 ? L"&Cancel transcription" : L"&Record"));
    EnableWindow(GetDlgItem(window, recordID), TRUE);
    for (int id : {keyID, saveID, microphoneID, profilesID}) EnableWindow(GetDlgItem(window, id), recording == 0);
    updateModelAvailability(window, recording);
    EnableWindow(GetDlgItem(window, processingID), recording == 0 && jsti_postprocessing_available());
    EnableWindow(GetDlgItem(window, textOutputID), recording == 0 && jsti_text_output_available());
    EnableWindow(GetDlgItem(window, shortcutID), recording == 0 && jsti_hotkey_available());
    updateSettingsMenu(window, recording);
    {
        // The shortcut can change through its dialog; avoid repainting an unchanged label.
        const std::wstring label = jsti_hotkey_label();
        wchar_t shown[256] = {};
        GetDlgItemTextW(window, transcriptLabelID, shown, 256);
        if (label != shown) SetDlgItemTextW(window, transcriptLabelID, label.c_str());
    }
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
        const std::string nowSelected = selectedHistory(window);
        bool selectionChanged;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            selectionChanged = nowSelected != state.selectedHistoryID;
            state.selectedHistoryID = nowSelected;
        }
        // A different (or no) record is displayed: its version and playback
        // are unknown until the host reports them, so never keep the previous record's.
        // Playback belongs to the record rather than to this refresh: an explicit
        // re-selection of the same record (for example after Retry) keeps its last
        // report, because the host never re-sends an unchanged state such as paused.
        if (selectionChanged || explicitHistorySelection) {
            invalidateHistoryPresentation(window, true);
            // With no row selected no presentation follows, so a status the host
            // sent with this refresh (such as Ready on a fresh launch) is newer
            // than the placeholder and must stay visible.
            if (statusChanged && nowSelected.empty()) SetDlgItemTextW(window, statusID, status.c_str());
            applyVariant(window, -1, false, recording);
            if (selectionChanged) applyPlayback(window, playbackIdle, L"", !nowSelected.empty(), recording);
        }
        if (failed) showFailure(window, "Windows could not display the saved recording list.");
    }
    // A report for a record the user has since left is stale; the new row's
    // version stays unknown until its own report arrives.
    if (variantChanged && variantRecord == selectedHistory(window) &&
        (state.requestedVariant < 0 || state.requestedVariant == variant)) {
        applyVariant(window, variant, variantSwitchable, recording);
    }
    // Untagged text belongs to active capture or a result outside the History
    // selection. Saved-record text uses the atomic, identity-checked path below.
    if (transcriptChanged && (recording != 0 || selectedHistory(window).empty())) {
        SetDlgItemTextW(window, transcriptID, transcript.c_str());
        state.historyPresentationReady = selectedHistory(window).empty();
    }
    if (presentationChanged && presentation.record == selectedHistory(window) &&
        (state.requestedVariant < 0 || state.requestedVariant == presentation.variant)) {
        SetDlgItemTextW(window, transcriptID, presentation.transcript.c_str());
        SetDlgItemTextW(window, statusID, presentation.status.c_str());
        state.historyPresentationReady = presentation.variant >= 0;
        state.requestedVariant = presentation.variant;
        applyVariant(window, presentation.variant, presentation.switchable, recording);
    }
    if (playbackChanged) {
        const std::string nowSelected = selectedHistory(window);
        if (playbackRecord.empty()) applyPlayback(window, playbackIdle, L"", !nowSelected.empty(), recording);
        else if (playbackRecord == nowSelected) applyPlayback(window, playback, playbackText, true, recording);
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
        info->ptMinTrackSize = {scale(window, 820), minimumWindowHeight(window)};
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
    case profilesMessage:
        if (idleControl(window, profilesID) && IsWindowEnabled(window)) jsti_show_profiles(window);
        else jsti_cancel_profiles_request();
        return 0;
    case updateMessage:
        applyUpdate(window); return 0;
    case WM_HOTKEY:
        jsti_hotkey_message(window, message, wparam);
        return 0;
    case WM_TIMER:
        if (jsti_hotkey_message(window, message, wparam)) return 0;
        break;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case profilesID:
            if (idleControl(window, profilesID)) emit(window, 17);
            return 0;
        case recordID: emitRecording(window); return 0;
        case importID:
            if (idleControl(window, importID) && !liveSelection(window)) importAudio(window);
            return 0;
        case copyID: {
            if (!IsWindowEnabled(GetDlgItem(window, copyID))) return 0;
            const std::string id = selectedHistory(window);
            emit(window, JSTI_EVENT_COPY_TRANSCRIPT, id.c_str());
            return 0;
        }
        case processingID: jsti_show_postprocessing(window); return 0;
        case menuShortcutID: case menuTextOutputID: case menuVoiceID: case menuPostProcessingID:
        case menuLocalModelsID: case menuCloudSyncID: {
            const int recording = jsti_window_recording_state();
            const HMENU menu = GetMenu(window);
            if (!menu || recording != 0 || !IsWindowEnabled(window) ||
                (GetMenuState(menu, LOWORD(wparam), MF_BYCOMMAND) & MF_GRAYED)) return 0;
            if (LOWORD(wparam) == menuShortcutID) {
                jsti_show_hotkey_settings(window);
                SetDlgItemTextW(window, transcriptLabelID, jsti_hotkey_label().c_str());
            } else if (LOWORD(wparam) == menuTextOutputID) {
                jsti_show_text_output(window);
            } else if (LOWORD(wparam) == menuVoiceID) {
                jsti_show_voice_settings(window);
            } else if (LOWORD(wparam) == menuLocalModelsID) {
                jsti_show_local_models(window);
            } else if (LOWORD(wparam) == menuCloudSyncID) {
                jsti_show_cloud_sync_settings(window);
            } else {
                jsti_show_postprocessing(window);
            }
            return 0;
        }
        case menuAutomationID: {
            bool enabled;
            { std::lock_guard<std::mutex> lock(state.mutex); enabled = state.automationEnabled; }
            emit(window, JSTI_EVENT_AUTOMATION_TOGGLED, enabled ? "0" : "1");
            return 0;
        }
        case textOutputID:
            // Only while idle and not already behind another modal editor.
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, textOutputID) && IsWindowEnabled(window)) {
                jsti_show_text_output(window);
            }
            return 0;
        case shortcutID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, shortcutID) && IsWindowEnabled(window)) {
                jsti_show_hotkey_settings(window);
                SetDlgItemTextW(window, transcriptLabelID, jsti_hotkey_label().c_str());
            }
            return 0;
        case retryID: emitHistory(window, JSTI_EVENT_HISTORY_RETRY); return 0;
        case exportID:
            if (IsWindowEnabled(GetDlgItem(window, exportID))) emitHistory(window, JSTI_EVENT_HISTORY_EXPORT);
            return 0;
        case openAudioID: emitHistory(window, JSTI_EVENT_HISTORY_OPEN_AUDIO); return 0;
        case readAloudID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, readAloudID))) {
                emitHistory(window, JSTI_EVENT_HISTORY_READ_ALOUD);
            }
            return 0;
        case voiceSettingsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, voiceSettingsID) && IsWindowEnabled(window)) {
                jsti_show_voice_settings(window);
            }
            return 0;
        case playPauseID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, playPauseID))) {
                emitHistory(window, JSTI_EVENT_HISTORY_PLAY_PAUSE);
            }
            return 0;
        case stopPlaybackID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, stopPlaybackID))) {
                emitHistory(window, JSTI_EVENT_HISTORY_STOP);
            }
            return 0;
        case historyID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                int recording;
                std::string nowSelected;
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    nowSelected = selectedHistory(window);
                    state.selectedHistoryID = nowSelected;
                    ++state.historyInteractionRevision;
                    recording = state.recording;
                }
                invalidateHistoryPresentation(window, true);
                applyVariant(window, -1, false, recording);
                applyPlayback(window, playbackIdle, L"", !nowSelected.empty(), recording);
                updateHistoryControls(window, recording);
                emitHistory(window, JSTI_EVENT_HISTORY_SELECTED);
            }
            return 0;
        case searchID:
            if (HIWORD(wparam) == EN_CHANGE) searchChanged(window);
            return 0;
        case clearSearchID:
            if (idleControl(window, clearSearchID)) clearSearch(window);
            return 0;
        case IDCANCEL:
            // Escape inside the search box is a keyboard clear affordance.
            if (GetFocus() == GetDlgItem(window, searchID) && idleControl(window, searchID)) clearSearch(window);
            return 0;
        case variantID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, variantID, CB_GETCURSEL, 0, 0);
                if (!idleControl(window, variantID) || !state.variantSwitchable || (chosen != 0 && chosen != 1)) {
                    SendDlgItemMessageW(window, variantID, CB_SETCURSEL, state.displayedVariant < 0
                        ? static_cast<WPARAM>(-1) : static_cast<WPARAM>(state.displayedVariant), 0);
                    return 0;
                }
                { std::lock_guard<std::mutex> lock(state.mutex); ++state.historyInteractionRevision; }
                state.displayedVariant = static_cast<int>(chosen);
                state.requestedVariant = state.displayedVariant;
                invalidateHistoryPresentation(window, false);
                emitHistory(window, JSTI_EVENT_TRANSCRIPT_VARIANT);
            }
            return 0;
        case microphoneID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, microphoneID)) { populateMicrophones(window); return 0; }
                const std::string device = selectedMicrophone(window);
                state.microphoneSelection = device;
                emit(window, JSTI_EVENT_MICROPHONE_CHANGED, device.c_str());
            }
            return 0;
        case modelRefreshID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, modelRefreshID))) {
                emit(window, JSTI_EVENT_REFRESH_MODELS);
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
        case localModelsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, localModelsID) && IsWindowEnabled(window)) {
                jsti_show_local_models(window);
            }
            return 0;
        case sourceID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT source = SendDlgItemMessageW(window, sourceID, CB_GETCURSEL, 0, 0);
                if (!idleControl(window, sourceID) || (source != 0 && source != 1) || source == activeSource()) {
                    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
                    return 0;
                }
                // Keep Batch or Live when the other source offers it.
                const int same = static_cast<int>(source) * 2 + state.activeMode % 2;
                const int other = static_cast<int>(source) * 2 + (1 - state.activeMode % 2);
                const int mode = state.preferredModels[same] >= 0 ? same : other;
                if (state.preferredModels[mode] < 0) {
                    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
                    return 0;
                }
                state.activeMode = mode;
                if (!populateModels(window)) { showFailure(window, "Windows could not display this source's models."); return 0; }
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
            }
            return 0;
        case modeID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, modeID)) {
                    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, state.activeMode % 2, 0);
                    return 0;
                }
                const LRESULT choice = SendDlgItemMessageW(window, modeID, CB_GETCURSEL, 0, 0);
                if (choice != 0 && choice != 1) return 0;
                const int mode = activeSource() * 2 + static_cast<int>(choice);
                if (state.preferredModels[mode] < 0) return 0;
                state.activeMode = mode;
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
        jsti_hotkey_stop(window);
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = nullptr; state.posted = false; }
        PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

// Shortcut events from WindowsHotKey.cpp, on the UI thread. A press-to-toggle
// press behaves exactly like the former fixed shortcut; gesture presses carry
// the selected microphone so the host can start with the device in view.
void jsti_window_hotkey_event(HWND window, int event) {
    switch (event) {
    case JSTI_EVENT_TOGGLE_RECORDING:
        if (IsWindowEnabled(GetDlgItem(window, recordID))) emitRecording(window);
        break;
    case JSTI_EVENT_HOTKEY_DOWN: {
        const std::string device = selectedMicrophone(window);
        emit(window, event, device.c_str());
        break;
    }
    case JSTI_EVENT_HOTKEY_UP:
    case JSTI_EVENT_HOTKEY_DEADLINE: emit(window, event); break;
    default: break;
    }
}

int jsti_window_set_automation(int enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    state.automationEnabled = enabled == 1;
    if (state.window && !state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return 0;
}

int jsti_window_recording_state() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.recording;
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
        state.modelOrder.resize(count);
        for (size_t index = 0; index < count; ++index) state.modelOrder[index] = static_cast<int>(index);
        if (!state.pendingModels.empty()) {
            if (state.pendingModels.size() != count) return jsti::fail("The discovered model catalogue has the wrong slot count.", error, capacity);
            for (size_t index = 0; index < count; ++index) {
                const auto &row = state.pendingModels[index];
                if (row.mode != state.modelModes[index]) return jsti::fail("The discovered model catalogue has inconsistent modes.", error, capacity);
                state.modelNames[index] = row.name;
                state.modelOrder[index] = row.order;
            }
        }
        state.pendingModels.clear(); state.modelsChanged = false;
        for (int mode = 0; mode < modeCount; ++mode) {
            const auto first = std::find(state.modelModes.begin(), state.modelModes.end(), mode);
            state.preferredModels[mode] = first == state.modelModes.end() ? -1 : static_cast<int>(first - state.modelModes.begin());
        }
        // Configured batch and live preferences belong to whichever source holds them.
        for (const int preferred : state.configuredPreferredModels) {
            if (preferred >= 0) state.preferredModels[state.modelModes[preferred]] = preferred;
        }
        if (selected < 0 || static_cast<size_t>(selected) >= count) {
            selected = state.configuredPreferredModels[0] >= 0 ? state.configuredPreferredModels[0] : -1;
            for (int mode = 0; selected < 0 && mode < modeCount; ++mode) selected = state.preferredModels[mode];
        }
        state.activeMode = state.modelModes[selected];
        state.preferredModels[state.activeMode] = selected;
        state.filteredModels.clear();
        if (state.microphones.empty()) state.microphones.push_back({"", L"Default communications microphone"});
        state.running = true;
        state.recording = 0;
        state.microphonesChanged = false;
        state.pendingMicrophones.clear(); state.microphoneError.clear();
        state.posted = false;
        state.statusChanged = false;
        state.transcriptChanged = false;
        state.historyChanged = false;
        state.historySelectionProvided = false;
        state.historyInteractionRevision = 0;
        state.pendingHistoryRevision = 0;
        state.variantChanged = false;
        state.presentationChanged = false;
        state.pendingPresentation = {};
        state.pendingVariantRecord.clear();
        state.pendingVariant = -1;
        state.pendingVariantSwitchable = false;
        state.playbackChanged = false;
        state.pendingPlaybackRecord.clear();
        state.pendingPlaybackState = playbackIdle;
        state.pendingPlaybackText.clear();
        state.pendingHistory.clear(); state.pendingHistorySelection.clear(); state.selectedHistoryID.clear();
        state.status.clear(); state.transcript.clear();
    }
    state.callback = callback; state.context = context;
    state.controls.clear();
    state.displayedHistory.clear();
    state.displayedVariant = -1;
    state.variantSwitchable = false;
    state.historyPresentationReady = false;
    state.requestedVariant = -1;
    state.displayedPlayback = playbackIdle;
    state.suppressSearchEvents = false;
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
        1100, 804, nullptr, createSettingsMenu(), instance, nullptr) : nullptr;
    int outcome = 0;
    if (!window) outcome = jsti::fail(jsti::systemError("Creating native desktop window"), error, capacity);
    else {
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = window; }
        ShowWindow(window, SW_SHOWDEFAULT);
        UpdateWindow(window);
        emit(window, JSTI_EVENT_READY);
        std::string shortcutFailure;
        if (IsWindow(window) && !jsti_hotkey_start(window, shortcutFailure)) showFailure(window, shortcutFailure);
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

int jsti_window_set_model_modes(const int *rowModes, size_t count, int preferredBatch, int preferredLive,
                                int preferredLocal) {
    if (count > 10000 || (count && !rowModes)) return -1;
    try {
        std::vector<int> modes;
        if (count) modes.assign(rowModes, rowModes + count);
        if (std::any_of(modes.begin(), modes.end(), [](int mode) { return mode < 0 || mode >= modeCount; })) return -1;
        const int preferred[] = {preferredBatch, preferredLive, preferredLocal};
        for (int mode = 0; mode < 3; ++mode) {
            const int index = preferred[mode];
            if (index < -1 || (index >= 0 && (static_cast<size_t>(index) >= count || modes[index] != mode))) return -1;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return -1;
        state.configuredModelModes = std::move(modes);
        state.configuredPreferredModels[0] = preferredBatch;
        state.configuredPreferredModels[1] = preferredLive;
        state.configuredPreferredModels[2] = preferredLocal;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_model_catalog(const JSTIModelRow *rows, size_t count, const char *status, int refreshing) {
    if (!rows || !count || count > 10000 || (refreshing != 0 && refreshing != 1)) return -1;
    try {
        std::vector<ModelRow> models;
        std::unordered_set<std::string> identifiers;
        std::unordered_set<int> ranks;
        std::wstring wideStatus;
        if (status && (!jsti::wide(status, wideStatus) || wideStatus.size() > 4096)) return -1;
        for (size_t index = 0; index < count; ++index) {
            const auto &row = rows[index];
            std::wstring id, name;
            if (!row.id || !row.name || !jsti::wide(row.id, id) || !jsti::wide(row.name, name) ||
                id.empty() || name.empty() || id.size() > 4096 || name.size() > 4096 ||
                (row.is_live != 0 && row.is_live != 1) || (row.is_local != 0 && row.is_local != 1) ||
                row.display_order < -1 ||
                row.display_order >= static_cast<int>(count) || !identifiers.insert(row.id).second ||
                (row.display_order >= 0 && !ranks.insert(row.display_order).second)) return -1;
            models.push_back({row.id, std::move(name), row.is_live + 2 * row.is_local, row.display_order});
        }
        std::vector<std::pair<std::string, int>> identities;
        for (const auto &row : models) identities.emplace_back(row.id, row.mode);
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) {
            if (state.knownModelIdentities.empty() || count < state.knownModelIdentities.size()) return -1;
            for (size_t index = 0; index < state.knownModelIdentities.size(); ++index) {
                if (models[index].id != state.knownModelIdentities[index].first ||
                    models[index].mode != state.knownModelIdentities[index].second) return -1;
            }
        }
        state.knownModelIdentities = std::move(identities);
        state.pendingModels = std::move(models);
        state.modelsChanged = true;
        state.modelsRefreshing = refreshing != 0;
        if (status) state.modelStatus = std::move(wideStatus);
        if (state.window && !state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
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


int jsti_window_refresh_microphones(const JSTIAudioDevice *devices, size_t count, const char *error) {
    if ((!devices && count) || count > 512) return -1;
    try {
        std::vector<MicrophoneRow> copied;
        std::wstring warning;
        if (error) {
            if (!jsti::wide(error, warning) || warning.empty() || warning.size() > 4096) return -1;
        } else {
            std::unordered_set<std::string> identifiers;
            std::wstring defaultName;
            copied.push_back({"", L"Default communications microphone"});
            for (size_t index = 0; index < count; ++index) {
                std::wstring identifier, name;
                if (!jsti::wide(devices[index].id, identifier) || identifier.empty() || identifier.size() > 4096 ||
                    !jsti::wide(devices[index].name, name) || name.empty() || name.size() > 4096 ||
                    !identifiers.insert(devices[index].id).second ||
                    (devices[index].is_default != 0 && devices[index].is_default != 1)) return -1;
                if (devices[index].is_default) {
                    if (!defaultName.empty()) return -1;
                    defaultName = name;
                    name += L" (system default)";
                }
                copied.push_back({devices[index].id, std::move(name)});
            }
            if (!defaultName.empty()) copied[0].name += L" — " + defaultName;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window || !state.running) return -1;
        if (!error) state.pendingMicrophones = std::move(copied);
        state.microphoneError = std::move(warning);
        state.microphonesChanged = true;
        if (!state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        return state.posted ? 0 : -1;
    } catch (...) { return -1; }
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

void jsti_window_request_profiles(void) {
    bool posted = false;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        posted = state.window && PostMessageW(state.window, profilesMessage, 0, 0);
    }
    if (!posted) jsti_cancel_profiles_request();
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
        state.pendingHistoryRevision = state.historyInteractionRevision;
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

int jsti_window_set_transcript_variant(const char *recordID, int selected, int canSwitch) {
    if (selected < -1 || selected > 1 || (canSwitch != 0 && canSwitch != 1)) return -1;
    std::wstring checked;
    if (recordID && (!jsti::wide(recordID, checked) || checked.size() > 128)) return -1;
    try {
        std::string record = recordID ? recordID : "";
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        state.pendingVariant = record.empty() ? -1 : selected;
        state.pendingVariantRecord = std::move(record);
        state.pendingVariantSwitchable = canSwitch != 0;
        state.variantChanged = true;
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
        state.pendingPresentation = std::move(presentation);
        state.presentationChanged = true;
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
    if (!state.historyPresentationReady || (!selectedHistory(window).empty() && recording != 0)) return -1;
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
    return selectedHistory(window).empty() ? -1 : state.displayedVariant;
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
        state.pendingPlaybackState = record.empty() ? playbackIdle : playback;
        state.pendingPlaybackRecord = std::move(record);
        state.pendingPlaybackText = std::move(text);
        state.playbackChanged = true;
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

int jsti_window_self_test(char *error, size_t errorCapacity) {
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("Window checks must run on the UI thread after READY.", error, errorCapacity);
    }
    const std::vector<MicrophoneRow> originalMicrophones = state.microphones;
    const std::string originalMicrophoneID = state.microphoneSelection;
    const std::vector<HistoryRow> originalHistory = state.displayedHistory;
    const std::string originalSelection = selectedHistory(window);
    const std::vector<std::wstring> originalModelNames = state.modelNames;
    const std::vector<int> originalModelModes = state.modelModes;
    const std::vector<int> originalModelOrder = state.modelOrder;
    std::vector<std::pair<std::string, int>> originalModelIdentities;
    std::wstring originalModelStatus;
    bool originalRefreshing;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        originalModelIdentities = state.knownModelIdentities;
        originalModelStatus = state.modelStatus;
        originalRefreshing = state.modelsRefreshing;
    }
    int originalPreferredModels[modeCount];
    std::copy(std::begin(state.preferredModels), std::end(state.preferredModels), originalPreferredModels);
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
        SetWindowPos(window, nullptr, 0, 0, scale(window, 820), minimumWindowHeight(window),
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
        state.modelOrder = {0, 1, 2, 3};
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.knownModelIdentities = {{"batch-a", 0}, {"live-a", 1}, {"batch-b", 0}, {"live-b", 1}};
        }
        state.preferredModels[0] = 2;
        state.preferredModels[1] = 3;
        state.preferredModels[2] = state.preferredModels[3] = -1; // No local rows in this fixture.
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
        const int beforeModalRecording = observed.event;
        EnableWindow(window, FALSE);
        SendMessageW(window, WM_HOTKEY, hotkeyID, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
        const bool modalBlocked = observed.event == beforeModalRecording;
        EnableWindow(window, TRUE);
        SendMessageW(window, WM_HOTKEY, hotkeyID, 0);
        if (!modalBlocked || observed.event != JSTI_EVENT_TOGGLE_RECORDING || observed.model != 1) {
            failure = "A modal editor allowed background recording, or recording did not recover on close."; return false;
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
        // A catalogue can reorder and retire visible rows while native events
        // continue to carry append-only global identities. Refreshing never
        // emits a model change or unlocks the recording controls.
        JSTIModelRow refreshedModels[] = {
            {"batch-a", "Renamed Alpha", 0, 3, 0}, {"live-a", "Unavailable Live One", 1, -1, 0},
            {"batch-b", "Batch Beta", 0, 1, 0}, {"live-b", "Retired Live Two", 1, -1, 0},
            {"discovered", "Discovered Batch", 0, 0, 0}
        };
        const int beforeRefresh = observed.event;
        jsti_window_update("Recording status sentinel", "Transcript sentinel", 1);
        applyUpdate(window);
        if (jsti_window_set_model_catalog(refreshedModels, 5, "Refreshing models", 1) != 0) {
            failure = "An append-only model refresh was rejected."; return false;
        }
        applyUpdate(window);
        wchar_t preservedStatus[64] = {}, preservedTranscript[64] = {};
        GetDlgItemTextW(window, statusID, preservedStatus, 64);
        GetDlgItemTextW(window, transcriptID, preservedTranscript, 64);
        if (selection(window) != 1 || observed.event != beforeRefresh ||
            SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 1 ||
            IsWindowEnabled(GetDlgItem(window, modelID)) || IsWindowEnabled(GetDlgItem(window, modelRefreshID)) ||
            std::wstring(preservedStatus) != L"Recording status sentinel" ||
            std::wstring(preservedTranscript) != L"Transcript sentinel") {
            failure = "Discovery changed a selected model, recording state or transcript."; return false;
        }
        if (jsti_window_set_model_catalog(refreshedModels, 4, "Invalid shrink", 0) != -1) {
            failure = "A refresh was allowed to shrink native identity slots."; return false;
        }
        refreshedModels[0].id = "replacement";
        if (jsti_window_set_model_catalog(refreshedModels, 5, nullptr, 0) != -1) {
            failure = "A refresh replaced an existing model identity."; return false;
        }
        refreshedModels[0].id = "batch-a";
        refreshedModels[0].is_live = 1;
        if (jsti_window_set_model_catalog(refreshedModels, 5, nullptr, 0) != -1) {
            failure = "A refresh changed an existing model mode."; return false;
        }
        refreshedModels[0].is_live = 0;
        refreshedModels[4].display_order = 1;
        if (jsti_window_set_model_catalog(refreshedModels, 5, nullptr, 0) != -1) {
            failure = "A refresh admitted ambiguous visible model positions."; return false;
        }
        refreshedModels[4].display_order = 0;
        jsti_window_update(nullptr, nullptr, 0);
        if (jsti_window_set_model_catalog(refreshedModels, 5, "Models refreshed", 0) != 0) {
            failure = "A completed model refresh was rejected."; return false;
        }
        applyUpdate(window);
        if (!changeMode(0, 0) || SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 3) {
            failure = "A refreshed picker lost its preferred batch model."; return false;
        }
        SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
        if (observed.model != 4 || selection(window) != 4) {
            failure = "A discovered model callback leaked its display position."; return false;
        }
        refreshedModels[4].display_order = -1;
        if (jsti_window_set_model_catalog(refreshedModels, 5, "Selected model unavailable", 0) != 0) {
            failure = "A selected model could not be retained after retirement."; return false;
        }
        applyUpdate(window);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelRefreshID, BN_CLICKED), 0);
        if (observed.event != JSTI_EVENT_REFRESH_MODELS || observed.model != 4 || selection(window) != 4 ||
            !changeMode(1, 1)) {
            failure = "Refresh changed the selected model identity or mode preference."; return false;
        }
        // Restore the fixture directly; the public API deliberately forbids
        // shrinking identities even after a model has disappeared from discovery.
        state.modelNames = {L"Batch Alpha", L"Live One", L"Batch Beta", L"Live Two"};
        state.modelModes = {0, 1, 0, 1};
        state.modelOrder = {0, 1, 2, 3};
        state.preferredModels[0] = 0;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.knownModelIdentities = {{"batch-a", 0}, {"live-a", 1}, {"batch-b", 0}, {"live-b", 1}};
        }
        if (!populateModels(window)) { failure = "Model fixture restoration failed."; return false; }
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
        const JSTIAudioDevice connected[] = {{"usb-a", "USB Alpha", 1}, {"usb-b", "USB Beta", 0}};
        observed.event = -500;
        if (jsti_window_refresh_microphones(connected, 2, nullptr) != 0) {
            failure = "A live microphone snapshot was rejected."; return false;
        }
        applyUpdate(window);
        SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, 1, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(microphoneID, CBN_SELCHANGE), 0);
        if (observed.event != JSTI_EVENT_MICROPHONE_CHANGED || observed.id != "usb-a") {
            failure = "A refreshed microphone did not keep its opaque ID."; return false;
        }
        observed.event = -500;
        const size_t beforeRecordingMicrophoneCount = state.microphones.size();
        jsti_window_update("Microphone refresh status sentinel", "Microphone transcript sentinel", 1);
        applyUpdate(window);
        const JSTIAudioDevice removed[] = {{"usb-b", "USB Beta", 1}};
        if (jsti_window_refresh_microphones(removed, 1, nullptr) != 0) {
            failure = "A microphone removal during capture was rejected."; return false;
        }
        applyUpdate(window);
        if (selectedMicrophone(window) != "usb-a" || state.microphones.size() != beforeRecordingMicrophoneCount ||
            IsWindowEnabled(GetDlgItem(window, microphoneID)) || observed.event != -500) {
            failure = "Hot-plug replaced the active capture selection or unlocked controls."; return false;
        }
        SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(microphoneID, CBN_SELCHANGE), 0);
        if (selectedMicrophone(window) != "usb-a" || observed.event != -500) {
            failure = "A synthetic selection change bypassed microphone lockout."; return false;
        }
        jsti_window_update(nullptr, nullptr, 0);
        applyUpdate(window);
        if (selectedMicrophone(window) != "usb-a" || state.microphones.size() != 3 ||
            state.microphones.back().name.find(L"unavailable") == std::wstring::npos ||
            state.microphones.front().name.find(L"USB Beta") == std::wstring::npos || observed.event != -500) {
            failure = "An unplugged selection silently changed or lost its unavailable/default label."; return false;
        }
        const JSTIAudioDevice restored[] = {{"usb-b", "USB Beta", 1}, {"usb-a", "USB Alpha renamed", 0}};
        jsti_window_refresh_microphones(restored, 2, nullptr);
        applyUpdate(window);
        if (selectedMicrophone(window) != "usb-a" || state.microphones.size() != 3 ||
            state.microphones.back().name != L"USB Alpha renamed" || observed.event != -500) {
            failure = "A restored microphone lost the selected ID or kept an unavailable label."; return false;
        }
        wchar_t microphoneStatus[128]{}, microphoneTranscript[128]{};
        GetDlgItemTextW(window, statusID, microphoneStatus, 128);
        GetDlgItemTextW(window, transcriptID, microphoneTranscript, 128);
        if (std::wstring(microphoneStatus) != L"Microphone refresh status sentinel" ||
            std::wstring(microphoneTranscript) != L"Microphone transcript sentinel") {
            failure = "Microphone refresh overwrote the recording status or transcript."; return false;
        }
        SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(microphoneID, CBN_SELCHANGE), 0);
        observed.event = -500;
        const JSTIAudioDevice duplicate[] = {connected[0], connected[0]};
        const JSTIAudioDevice malformed[] = {{"\xff", "Invalid", 0}};
        if (jsti_window_refresh_microphones(duplicate, 2, nullptr) != -1 ||
            jsti_window_refresh_microphones(malformed, 1, nullptr) != -1) {
            failure = "Invalid or duplicate microphone identities were accepted."; return false;
        }
        jsti_window_refresh_microphones(removed, 1, nullptr);
        jsti_window_refresh_microphones(connected, 1, nullptr);
        applyUpdate(window);
        if (!selectedMicrophone(window).empty() || state.microphones.size() != 2 ||
            state.microphones.front().name.find(L"USB Alpha") == std::wstring::npos || observed.event != -500) {
            failure = "Microphone snapshots did not coalesce or the dynamic default changed ID."; return false;
        }
        jsti_window_refresh_microphones(removed, 1, nullptr);
        jsti_window_refresh_microphones(nullptr, 0, "Synthetic enumeration error");
        applyUpdate(window);
        if (state.microphones.size() != 2 || !selectedMicrophone(window).empty() ||
            state.microphones.front().name.find(L"USB Beta") == std::wstring::npos) {
            failure = "An enumeration failure discarded the last complete microphone snapshot."; return false;
        }
        jsti_window_refresh_microphones(nullptr, 0, nullptr);
        applyUpdate(window);
        if (state.microphones.size() != 1 || !selectedMicrophone(window).empty() || observed.event != -500) {
            failure = "No active microphones did not retain the dynamic default without emitting a user change."; return false;
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
        observed.event = -500;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(stopPlaybackID, BN_CLICKED), 0);
        if (observed.event != -500) { failure = "A disabled Stop emitted a playback event."; return false; }
        if (jsti_window_set_playback("one", 4, "bad") != -1 || jsti_window_set_playback("\xff", 2, "bad") != -1 ||
            jsti_window_set_playback("two", playbackPlaying, "00:00.10 / 00:01.90") != 0) {
            failure = "Playback report validation failed."; return false;
        }
        applyUpdate(window);
        if (state.displayedPlayback != playbackIdle || playbackLabel() != L"Play" ||
            IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || playbackTime() != playbackIdleText) {
            failure = "A playback report for another record changed the selected row's controls."; return false;
        }
        if (jsti_window_set_playback("one", playbackPreparing, "00:00.00 / 00:02.00") != 0 ||
            jsti_window_set_playback("one", playbackPlaying, "00:00.10 / 00:01.90") != 0) {
            failure = "Playback reports for the selected record were rejected."; return false;
        }
        applyUpdate(window);
        if (state.displayedPlayback != playbackPlaying || playbackLabel() != L"Pause" ||
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
        const bool pausedWhileRecording = state.displayedPlayback == playbackPaused && playbackLabel() == L"Play" &&
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
        if (selectedHistory(window) != "one" || state.displayedPlayback != playbackPaused || playbackLabel() != L"Play" ||
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
        if (observed.event != JSTI_EVENT_HISTORY_SELECTED || observed.id != "two" || state.displayedPlayback != playbackIdle ||
            playbackLabel() != L"Play" || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) || playbackTime() != playbackIdleText) {
            failure = "Selecting another record did not reset the playback display."; return false;
        }
        jsti_window_set_playback("one", playbackPlaying, "00:01.10 / 00:00.90");
        applyUpdate(window);
        if (state.displayedPlayback != playbackIdle || IsWindowEnabled(GetDlgItem(window, stopPlaybackID))) {
            failure = "A stale playback report was applied to a different record."; return false;
        }
        jsti_window_set_playback("two", playbackPlaying, "00:00.20 / 00:00.80");
        applyUpdate(window);
        jsti_window_set_playback("", playbackPlaying, nullptr);
        applyUpdate(window);
        if (state.displayedPlayback != playbackIdle || IsWindowEnabled(GetDlgItem(window, stopPlaybackID)) ||
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
        if (std::wstring(detail) != L"No saved recordings match this search.") {
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
        RECT profileButton{}, modelLabel{};
        GetWindowRect(GetDlgItem(window, profilesID), &profileButton);
        GetWindowRect(GetDlgItem(window, 90), &modelLabel);
        if (!IsWindowVisible(GetDlgItem(window, profilesID)) || profileButton.bottom > modelLabel.top) {
            failure = "The all-batch catalogue overlapped App profiles and the model label."; return false;
        }
        // A host initially exposing only batch can add its first live route
        // without restarting or changing the current batch preference.
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.knownModelIdentities = {{"batch-a", 0}, {"batch-b", 0}, {"batch-c", 0}, {"batch-d", 0}};
        }
        const JSTIModelRow firstLive[] = {
            {"batch-a", "Batch Alpha", 0, 0, 0}, {"batch-b", "Batch Beta", 0, 1, 0},
            {"batch-c", "Batch Gamma", 0, 2, 0}, {"batch-d", "Batch Delta", 0, 3, 0},
            {"first-live", "First Live", 1, 4, 0}
        };
        const int eventBeforeFirstLive = observed.event;
        if (jsti_window_set_model_catalog(firstLive, 5, "Live now available", 0) != 0) {
            failure = "The first live mode could not be appended."; return false;
        }
        applyUpdate(window);
        RECT modeBounds{}, labelBounds{}, windowBounds{};
        GetWindowRect(GetDlgItem(window, modeID), &modeBounds);
        GetWindowRect(GetDlgItem(window, 90), &labelBounds);
        GetWindowRect(window, &windowBounds);
        if (!hasModeChoice() || !IsWindowVisible(GetDlgItem(window, modeID)) || selection(window) != 2 ||
            observed.event != eventBeforeFirstLive || modeBounds.bottom > labelBounds.top ||
            windowBounds.bottom - windowBounds.top < minimumWindowHeight(window) || !checkBounds() ||
            !changeMode(1, 4)) {
            failure = "Adding the first live mode lost its preference or overlapped the model controls."; return false;
        }
        // Source picker: Remote and Local each keep their own preference, the
        // Local source has no Live mode here, and callbacks keep global indices.
        state.modelNames = {L"Remote Batch", L"Remote Live", L"Local Batch"};
        state.modelModes = {0, 1, 2};
        state.modelOrder = {0, 1, 2};
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.knownModelIdentities = {{"remote-batch", 0}, {"remote-live", 1}, {"local-batch", 2}};
        }
        state.preferredModels[0] = 0;
        state.preferredModels[1] = 1;
        state.preferredModels[2] = 2;
        state.preferredModels[3] = -1;
        state.activeMode = 0;
        auto changeSource = [&](int source, int expected) {
            SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, source, 0);
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(sourceID, CBN_SELCHANGE), 0);
            return observed.event == JSTI_EVENT_MODEL_CHANGED && observed.model == expected && selection(window) == expected;
        };
        wchar_t localLabel[64] = {};
        const bool remoteShown = populateModels(window) && hasSourceChoice() && checkBounds() &&
            IsWindowVisible(GetDlgItem(window, sourceID)) && IsWindowEnabled(GetDlgItem(window, sourceID)) &&
            IsWindowVisible(GetDlgItem(window, modelRefreshID)) && !IsWindowVisible(GetDlgItem(window, localModelsID)) &&
            IsWindowVisible(GetDlgItem(window, modeID));
        const bool localChosen = changeSource(1, 2) && !IsWindowVisible(GetDlgItem(window, modeID)) &&
            IsWindowVisible(GetDlgItem(window, localModelsID)) && !IsWindowVisible(GetDlgItem(window, modelRefreshID)) &&
            IsWindowEnabled(GetDlgItem(window, importID)) && checkBounds() &&
            GetDlgItemTextW(window, 90, localLabel, 64) > 0 && std::wstring(localLabel).find(L"On-device") == 0;
        jsti_window_update(nullptr, nullptr, 1);
        applyUpdate(window);
        const bool sourceLocked = !IsWindowEnabled(GetDlgItem(window, sourceID)) &&
            !IsWindowEnabled(GetDlgItem(window, localModelsID));
        jsti_window_update(nullptr, nullptr, 0);
        applyUpdate(window);
        if (!remoteShown || !localChosen || !sourceLocked || !changeSource(0, 0) || !changeMode(1, 1) ||
            !changeSource(1, 2) || !changeSource(0, 0)) {
            failure = "The Source picker lost a source preference, its controls or the global model identity."; return false;
        }
        // The Text output modal must block both background recording paths.
        auto setRecording = [](HWND owner, int recording) {
            jsti_window_update(nullptr, nullptr, recording);
            applyUpdate(owner);
        };
        auto recordingBlocked = [](HWND owner, void *context) {
            const int before = static_cast<Event *>(context)->event;
            SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
            SendMessageW(owner, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
            return static_cast<Event *>(context)->event == before;
        };
        auto observe = [](void *context) { return static_cast<Event *>(context)->event; };
        return jsti_settings_self_test(window, failure) && jsti_profiles_self_test(window, failure) &&
            jsti_text_output_settings_self_test(window, textOutputID, setRecording, recordingBlocked, &observed, failure) &&
            jsti_hotkey_self_test(window, observe, &observed, failure) && jsti_voice_settings_self_test(window, failure) &&
            jsti_local_models_self_test(window, failure) && jsti_cloud_sync_settings_self_test(window, failure);
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { failure = "Window smoke test could not allocate its temporary state."; }
    state.microphones = originalMicrophones;
    state.microphoneSelection = originalMicrophoneID;
    populateMicrophones(window);
    SetDlgItemTextW(window, 94, L"&Microphone");
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.microphonesChanged = false;
        state.pendingMicrophones.clear(); state.microphoneError.clear();
    }
    state.modelNames = originalModelNames;
    state.modelModes = originalModelModes;
    state.modelOrder = originalModelOrder;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.knownModelIdentities = std::move(originalModelIdentities);
        state.modelStatus = std::move(originalModelStatus);
        state.modelsRefreshing = originalRefreshing;
        state.modelsChanged = true;
        state.pendingModels.clear();
    }
    std::copy(std::begin(originalPreferredModels), std::end(originalPreferredModels), state.preferredModels);
    state.activeMode = originalMode;
    if (!populateModels(window)) { passed = false; failure = "The model catalogue could not be restored after its smoke test."; }
    state.suppressSearchEvents = true;
    SetDlgItemTextW(window, searchID, L"");
    state.suppressSearchEvents = false;
    applyVariant(window, -1, false, 0);
    applyPlayback(window, playbackIdle, L"", false, 0);
    state.callback = originalCallback;
    state.context = originalContext;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.pendingHistory = originalHistory;
        state.pendingHistorySelection = originalSelection;
        state.historySelectionProvided = true;
        state.pendingHistoryRevision = state.historyInteractionRevision;
        state.historyChanged = true;
        state.playbackChanged = false;
        state.pendingPlaybackRecord.clear();
        state.pendingPlaybackState = playbackIdle;
        state.pendingPlaybackText.clear();
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
