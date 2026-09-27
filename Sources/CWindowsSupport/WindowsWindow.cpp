#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commctrl.h>
#include <commdlg.h>
#include <cstdio>
#include <objbase.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <mutex>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "WindowsHUD.hpp"
#include "WindowsTray.hpp"
#include "WindowsWindowChrome.hpp"

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
bool jsti_azure_resource_available();
void jsti_show_azure_resource_settings(HWND owner);
bool jsti_azure_resource_settings_self_test(HWND owner, std::string &error);
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
// The Source picker (Remote/Local) and the Local models dialog button, which
// takes the place of Refresh models while the Local source is selected.
constexpr int sourceLabelID = 89;
constexpr int localModelsID = 174;
constexpr int sourceID = 175;
// Model modes: bit 0 is live, bit 1 is local (on-device).
constexpr int modeCount = 4;
constexpr int playbackIdle = 0, playbackPreparing = 1, playbackPlaying = 2, playbackPaused = 3;
const wchar_t *const playbackIdleText = L"00:00.00 / --:--";
// Pages, in sidebar order, as on the Mac: Speak, then Settings.
enum Page { dashboardPage, historyPage, voicePage, generalPage, transcriptionPage, postProcessingPage,
            profilesPage, keyboardPage, cloudSyncPage, aboutPage, pageCount };
struct PageInfo { const wchar_t *title; const wchar_t *subtitle; wchar_t glyph; const char *name; };
const PageInfo pageInfo[pageCount] = {
    {L"Dashboard", L"Ready to capture ideas instantly. Check your setup, follow your usage, and pick up your latest "
                   L"session.", 0xE80F, "dashboard"},
    {L"History", L"Search, replay and reuse past recordings and their transcripts.", 0xE81C, "history"},
    {L"Voice Output", L"Hear any History transcript read back in a Deepgram Aura voice, through your own Deepgram "
                      L"key.", 0xE767, "voice-output"},
    {L"General", L"Choose the microphone, where finished text goes, and how the app looks.", 0xE713, "general"},
    {L"Transcription", L"Pick the speech model for new recordings, on this PC or with your own provider key.", 0xE720,
     "transcription"},
    {L"Post-processing", L"Optionally polish transcripts with an OpenRouter model. The original is always kept.", 0xE734,
     "post-processing"},
    {L"Profiles", L"Give specific apps their own model, language and clean-up prompt.", 0xE77B, "profiles"},
    {L"Keyboard", L"Start and stop dictation from anywhere with a global shortcut.", 0xE765, "keyboard"},
    {L"iCloud Sync", L"Keep History in step with your Mac, through your own iCloud account.", 0xE753, "icloud-sync"},
    {L"About", L"Voice-to-text made simple. Windows developer preview.", 0xE946, "about"},
};
// Sidebar buttons are navBaseID + page. The values in the heroes, Insights and
// Setup are owner-drawn static controls, so screen readers read them.
constexpr int navBaseID = 300;
constexpr int chipSessionsID = 401, chipTimeID = 402, chipSpendID = 403;
constexpr int insightSessionsID = 411, insightTimeID = 412, insightAverageID = 413, insightSpendID = 414;
constexpr int historySessionsID = 421, historyErrorsID = 422, historyAverageID = 423, historySpendID = 424;
constexpr int setupMicrophoneID = 431, setupModelID = 432, setupShortcutID = 433, setupOutputID = 434;
// Settings that were menu commands: the automation switch emits
// AUTOMATION_TOGGLED; the others open the same dialogs as before.
constexpr int appearanceLabelID = 440, appearanceID = 441, automationID = 442, azureID = 443, cloudSyncID = 444,
    shortcutValueID = 445, githubID = 446, issueID = 447, privacyID = 448;
constexpr UINT tourMessage = WM_APP + 18, appearanceMessage = WM_APP + 19, pageMessage = WM_APP + 20;
constexpr UINT hudMessage = WM_APP + 21;
constexpr UINT_PTR tourTimerID = 90;
// How each owner-drawn control is drawn.
enum class Role { label, caption, status, detail, chipValue, statValue, tileValue, value, button, primary, record,
                  heroButton, nav, toggle, link };
struct HistoryRow {
    std::string id;
    std::wstring title;
    std::wstring detail;
    // The card: the shared DesktopHistoryRowSummary's wording.
    std::wstring created, audio, cost, preview, models, context;
    int tone = 0;
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
    // Pages and presentation (UI thread).
    int page = dashboardPage;
    std::unordered_map<int, bool> wanted;
    std::wstring headerSubtitle;
    int displayedRecording = 0;
    std::wstring traySummary;
    // Totals: [all, visible][sessions, errors, recording time, average, spend].
    std::wstring insights[2][5];
    bool insightsChanged = false;
    // The screenshot tour (UI thread).
    std::wstring tourDirectory;
    int tourStep = -1;
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

void setShown(HWND window, int identifier, bool shown);
void layout(HWND window);
void invalidateBackdrop(HWND window);

// Remote shows OpenRouter discovery and Refresh models; Local shows the
// on-device runtime and the Local models dialog.
void updateSourceControls(HWND window) {
    const bool local = activeSource() == 1;
    setShown(window, modelRefreshID, !local);
    setShown(window, localModelsID, local);
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
    const bool relayout = state.page == transcriptionPage &&
        (state.wanted.count(modeID) == 0 || state.wanted[modeID] != choice || state.wanted[sourceID] != hasSourceChoice());
    setShown(window, modeID, choice);
    setShown(window, 95, choice);
    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, state.activeMode % 2, 0);
    const bool sources = hasSourceChoice();
    setShown(window, sourceID, sources);
    setShown(window, sourceLabelID, sources);
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
    const wchar_t *label = activeSource() == 1 ? L"On-device &transcription model"
        : (!choice && state.activeMode == 1 ? L"Live &transcription model" : L"&Transcription model");
    SetDlgItemTextW(window, 90, label);
    updateSourceControls(window);
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    updateModelAvailability(window, recording);
    // The Model card grows or shrinks with the Source and Mode rows.
    if (relayout) layout(window);
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

void showPage(HWND window, int page);

// A command chosen from the notification area's menu, or its icon clicked.
void trayCommand(HWND window, UINT command) {
    if (command == jsti::tray::toggle) { emitRecording(window); return; }
    if (command == jsti::tray::quit) { PostMessageW(window, WM_CLOSE, 0, 0); return; }
    if (command != jsti::tray::open && command != jsti::tray::settings) return;
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
    if (command == jsti::tray::settings) showPage(window, generalPage);
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

// The smallest window every page fits in without scrolling, as the Mac's
// 960 × 640 main window minimum, plus the sidebar and status line.
int minimumWindowWidth(HWND window) { return scale(window, 980); }
int minimumWindowHeight(HWND window) { return scale(window, 760); }

// ------------------------------------------------------------------ pages

// Which pages show a control. Controls outside this list belong to Transcription.
unsigned pagesOf(int identifier) {
    constexpr unsigned all = (1u << pageCount) - 1;
    auto page = [](int value) { return 1u << value; };
    if (identifier >= navBaseID && identifier < navBaseID + pageCount) return all;
    switch (identifier) {
    case statusID: case recordID: case importID: return all;
    case transcriptID: case copyID: return page(dashboardPage) | page(historyPage);
    case transcriptLabelID: case chipSessionsID: case chipTimeID: case chipSpendID:
    case insightSessionsID: case insightTimeID: case insightAverageID: case insightSpendID:
    case setupMicrophoneID: case setupModelID: case setupShortcutID: case setupOutputID:
        return page(dashboardPage);
    case searchLabelID: case searchID: case clearSearchID: case 93: case historyID: case historyDetailID:
    case variantLabelID: case variantID: case retryID: case exportID: case openAudioID: case playbackLabelID:
    case playbackTimeID: case playPauseID: case historySessionsID: case historyErrorsID: case historyAverageID:
    case historySpendID:
        return page(historyPage);
    case readAloudID: case stopPlaybackID: return page(historyPage) | page(voicePage);
    case voiceSettingsID: return page(voicePage);
    case 94: case microphoneID: case textOutputID: case appearanceLabelID: case appearanceID: case automationID:
        return page(generalPage);
    case processingID: return page(postProcessingPage);
    case profilesID: return page(profilesPage);
    case shortcutValueID: case shortcutID: return page(keyboardPage);
    case cloudSyncID: return page(cloudSyncPage);
    case githubID: case issueID: case privacyID: return page(aboutPage);
    default: return page(transcriptionPage);
    }
}

bool onPage(int identifier, int page) { return (pagesOf(identifier) & (1u << page)) != 0; }

// Feature visibility (Mode, Source, Refresh or Local models) is remembered
// here and combined with the current page, so a hidden page never shows them.
void setShown(HWND window, int identifier, bool shown) {
    state.wanted[identifier] = shown;
    ShowWindow(GetDlgItem(window, identifier), shown && onPage(identifier, state.page) ? SW_SHOWNA : SW_HIDE);
}

void applyVisibility(HWND window) {
    for (HWND control : state.controls) {
        const int identifier = GetDlgCtrlID(control);
        const auto found = state.wanted.find(identifier);
        const bool shown = (found == state.wanted.end() || found->second) && onPage(identifier, state.page);
        if ((IsWindowVisible(control) != FALSE) != shown) ShowWindow(control, shown ? SW_SHOWNA : SW_HIDE);
    }
}

Role roleOf(HWND window, int identifier) {
    if (identifier >= navBaseID && identifier < navBaseID + pageCount) return Role::nav;
    switch (identifier) {
    case recordID: return Role::record;
    case copyID: case saveID: return Role::primary;
    case importID: return state.page == historyPage ? Role::heroButton : Role::button;
    case automationID: return Role::toggle;
    case statusID: return Role::status;
    case historyDetailID: case modelStatusID: case transcriptLabelID: return Role::caption;
    case playbackTimeID: case shortcutValueID: return Role::value;
    case chipSessionsID: case chipTimeID: case chipSpendID: case historySessionsID: case historyErrorsID:
    case historyAverageID: case historySpendID: return Role::chipValue;
    case insightSessionsID: case insightTimeID: case insightAverageID: case insightSpendID: return Role::statValue;
    case setupMicrophoneID: case setupModelID: case setupShortcutID: case setupOutputID: return Role::tileValue;
    default: break;
    }
    wchar_t kind[16] = {};
    GetClassNameW(GetDlgItem(window, identifier), kind, 16);
    return _wcsicmp(kind, L"STATIC") == 0 ? Role::label : Role::button;
}

// ----------------------------------------------------------------- frame

// What WM_PAINT draws behind the controls, laid out with them.
struct Card { RECT rect; wchar_t glyph; std::wstring title; };
struct Chip { RECT rect; std::wstring label; };
struct Paragraph { RECT rect; std::wstring text; jsti::chrome::Font font; bool secondary; };
struct Frame {
    RECT sidebar{}, header{}, status{}, hero{}, speakHeading{}, settingsHeading{}, icon{};
    jsti::chrome::Gradient gradient = jsti::chrome::Gradient::brand;
    std::wstring heroTitle, heroSubtitle;
    std::vector<Chip> chips;
    std::vector<Card> cards;
    std::vector<Chip> stats;
    std::vector<Card> tiles;
    std::vector<RECT> fields;
    std::vector<Paragraph> paragraphs;
} frame;

RECT box(int x, int y, int width, int height) { return RECT{x, y, x + width, y + height}; }
int widthOf(const RECT &rect) { return rect.right - rect.left; }
int heightOf(const RECT &rect) { return rect.bottom - rect.top; }

// Every control's client-area rectangle, as placed, for its painted backdrop.
std::unordered_map<int, RECT> placed;

void place(HWND window, int identifier, const RECT &rect) {
    placed[identifier] = rect;
    MoveWindow(GetDlgItem(window, identifier), rect.left, rect.top, widthOf(rect), heightOf(rect), FALSE);
}

// A text field: the control sits inside a painted rounded field.
void placeField(HWND window, int identifier, RECT rect, bool multiline = false) {
    frame.fields.push_back(rect);
    const int horizontal = scale(window, 10);
    const int vertical = multiline ? scale(window, 8) : std::max(0, (heightOf(rect) - scale(window, 20)) / 2);
    InflateRect(&rect, -horizontal, -vertical);
    place(window, identifier, rect);
}

std::wstring heroTitle(int page) {
    switch (page) {
    case dashboardPage: return L"Speak Dashboard";
    case historyPage: return L"Session History";
    default: return pageInfo[page].title;
    }
}

// A hero across the top of the content. Returns its bottom.
int layoutHero(HWND window, const RECT &content, int height, jsti::chrome::Gradient gradient) {
    frame.hero = box(content.left, content.top, widthOf(content), height);
    frame.gradient = gradient;
    frame.heroTitle = heroTitle(state.page);
    frame.heroSubtitle = pageInfo[state.page].subtitle;
    return frame.hero.bottom;
}

// Chips along the hero's bottom edge; each value is the static `ids[index]`.
void layoutChips(HWND window, const std::vector<std::pair<int, std::wstring>> &chips) {
    const int inset = scale(window, 26), spacing = scale(window, 12), height = scale(window, 62);
    const int available = widthOf(frame.hero) - 2 * inset - spacing * static_cast<int>(chips.size() - 1);
    const int width = std::min(scale(window, 190), available / static_cast<int>(chips.size()));
    const int top = frame.hero.bottom - inset - height;
    for (size_t index = 0; index < chips.size(); ++index) {
        const RECT chip = box(frame.hero.left + inset + static_cast<int>(index) * (width + spacing), top, width, height);
        frame.chips.push_back({chip, chips[index].second});
        place(window, chips[index].first, box(chip.left + scale(window, 14), chip.top + scale(window, 26),
                                              width - scale(window, 28), scale(window, 28)));
    }
}

Card &addCard(RECT rect, wchar_t glyph, const std::wstring &title) {
    frame.cards.push_back({rect, glyph, title});
    return frame.cards.back();
}

// The card's content area below its title row.
RECT cardBody(HWND window, const RECT &card) {
    return RECT{card.left + scale(window, 22), card.top + scale(window, 66), card.right - scale(window, 22),
                card.bottom - scale(window, 20)};
}

// Sets a control's text only when it changes, so layout never repaints needlessly.
void setLabel(HWND window, int identifier, const wchar_t *text) {
    wchar_t shown[64] = {};
    GetDlgItemTextW(window, identifier, shown, 64);
    if (wcscmp(shown, text) != 0) SetDlgItemTextW(window, identifier, text);
}

void layoutDashboard(HWND window, const RECT &content) {
    const int gap = scale(window, 18);
    const int heroBottom = layoutHero(window, content, scale(window, 200), jsti::chrome::Gradient::brand);
    place(window, recordID, box(frame.hero.right - scale(window, 26) - scale(window, 196), frame.hero.top + scale(window, 26),
                                scale(window, 196), scale(window, 50)));
    layoutChips(window, {{chipSessionsID, L"Sessions"}, {chipTimeID, L"Recording Time"}, {chipSpendID, L"Spend"}});
    const int rowHeight = scale(window, 190);
    const RECT transcript{content.left, heroBottom + gap, content.right, content.bottom - rowHeight - gap};
    addCard(transcript, 0xE70F, L"Transcript");
    place(window, transcriptLabelID, RECT{transcript.left + widthOf(transcript) / 3, transcript.top + scale(window, 26),
                                          transcript.right - scale(window, 22), transcript.top + scale(window, 46)});
    const RECT body = cardBody(window, transcript);
    const int buttonHeight = scale(window, 34);
    placeField(window, transcriptID, RECT{body.left, body.top, body.right, body.bottom - buttonHeight - scale(window, 12)}, true);
    place(window, copyID, box(body.right - scale(window, 156), body.bottom - buttonHeight, scale(window, 156), buttonHeight));
    setLabel(window, copyID, L"&Copy transcript");
    const int half = (widthOf(content) - gap) / 2;
    const RECT insights = box(content.left, content.bottom - rowHeight, half, rowHeight);
    const RECT setup = box(content.left + half + gap, content.bottom - rowHeight, widthOf(content) - half - gap, rowHeight);
    addCard(insights, 0xE9D2, L"Insights");
    addCard(setup, 0xE713, L"Setup");
    auto grid = [&](const RECT &card, int index) {
        const RECT inner = cardBody(window, card);
        const int spacing = scale(window, 10);
        const int width = (widthOf(inner) - spacing) / 2, height = (heightOf(inner) - spacing) / 2;
        return box(inner.left + (index % 2) * (width + spacing), inner.top + (index / 2) * (height + spacing), width, height);
    };
    const std::pair<int, const wchar_t *> stats[] = {
        {insightSessionsID, L"Sessions"}, {insightTimeID, L"Recording Time"},
        {insightAverageID, L"Average Length"}, {insightSpendID, L"Spend"}};
    for (int index = 0; index < 4; ++index) {
        const RECT tile = grid(insights, index);
        frame.stats.push_back({tile, stats[index].second});
        place(window, stats[index].first, RECT{tile.left + scale(window, 14), tile.bottom - scale(window, 30),
                                               tile.right - scale(window, 10), tile.bottom - scale(window, 6)});
    }
    const std::tuple<int, wchar_t, const wchar_t *> tiles[] = {
        {setupMicrophoneID, 0xE720, L"Microphone"}, {setupModelID, 0xE70F, L"Model"},
        {setupShortcutID, 0xE765, L"Shortcut"}, {setupOutputID, 0xE8C8, L"Text output"}};
    for (int index = 0; index < 4; ++index) {
        const RECT tile = grid(setup, index);
        frame.tiles.push_back({tile, std::get<1>(tiles[index]), std::get<2>(tiles[index])});
        place(window, std::get<0>(tiles[index]), RECT{tile.left + scale(window, 12), tile.top + scale(window, 28),
                                                      tile.right - scale(window, 8), tile.bottom - scale(window, 4)});
    }
}

void layoutHistory(HWND window, const RECT &content) {
    const int gap = scale(window, 18), row = scale(window, 34);
    const int heroBottom = layoutHero(window, content, scale(window, 168), jsti::chrome::Gradient::brand);
    place(window, importID, box(frame.hero.right - scale(window, 26) - scale(window, 124), frame.hero.top + scale(window, 24),
                                scale(window, 124), row));
    layoutChips(window, {{historySessionsID, L"Sessions"}, {historyErrorsID, L"Errors"},
                         {historyAverageID, L"Average Length"}, {historySpendID, L"Spend"}});
    const int searchTop = heroBottom + scale(window, 14);
    place(window, searchLabelID, box(content.left, searchTop + scale(window, 8), scale(window, 112), scale(window, 20)));
    placeField(window, searchID, RECT{content.left + scale(window, 116), searchTop,
                                      content.right - scale(window, 88), searchTop + row});
    place(window, clearSearchID, box(content.right - scale(window, 80), searchTop, scale(window, 80), row));
    const int top = searchTop + row + scale(window, 14);
    const int listWidth = (widthOf(content) - gap) * 13 / 25;
    place(window, 93, box(content.left, top, listWidth, scale(window, 20)));
    place(window, historyID, RECT{content.left, top + scale(window, 22), content.left + listWidth, content.bottom});
    const RECT detail{content.left + listWidth + gap, top, content.right, content.bottom};
    addCard(detail, 0xE8A5, L"Selected recording");
    const int inset = scale(window, 20);
    const int left = detail.left + inset, right = detail.right - inset;
    int y = detail.top + scale(window, 58);
    place(window, historyDetailID, RECT{left, y, right, y + scale(window, 34)});
    y += scale(window, 40);
    place(window, variantLabelID, box(left, y + scale(window, 7), scale(window, 128), scale(window, 20)));
    place(window, variantID, RECT{left + scale(window, 132), y, right, y + scale(window, 200)});
    y += row + scale(window, 10);
    const int actionsHeight = 3 * row + 2 * scale(window, 8) + scale(window, 26);
    placeField(window, transcriptID, RECT{left, y, right, detail.bottom - inset - actionsHeight - scale(window, 10)}, true);
    int actions = detail.bottom - inset - actionsHeight;
    place(window, playbackLabelID, box(left, actions, scale(window, 80), scale(window, 20)));
    place(window, playbackTimeID, RECT{left + scale(window, 84), actions, right, actions + scale(window, 20)});
    actions += scale(window, 26);
    auto cell = [&](int index, int top, int columns) {
        const int width = (right - left - (columns - 1) * scale(window, 8)) / columns;
        return box(left + index * (width + scale(window, 8)), top, width, row);
    };
    place(window, playPauseID, cell(0, actions, 3));
    place(window, stopPlaybackID, cell(1, actions, 3));
    place(window, copyID, cell(2, actions, 3));
    // A third of the card is too narrow for "Copy transcript"; the Mac says Copy here too.
    setLabel(window, copyID, L"&Copy");
    actions += row + scale(window, 8);
    place(window, readAloudID, cell(0, actions, 2));
    place(window, retryID, cell(1, actions, 2));
    actions += row + scale(window, 8);
    place(window, exportID, cell(0, actions, 2));
    place(window, openAudioID, cell(1, actions, 2));
}

// A settings card: `rows` controls, top to bottom, with a description.
int layoutSettingsCard(HWND window, int top, const RECT &content, wchar_t glyph, const std::wstring &title,
                       const std::wstring &description, int contentHeight) {
    const int inset = scale(window, 22);
    HDC dc = GetDC(window);
    const int textHeight = description.empty() ? 0 : jsti::chrome::measure(dc, description,
        widthOf(content) - 2 * inset, jsti::chrome::Font::body, GetDpiForWindow(window));
    ReleaseDC(window, dc);
    const int height = scale(window, 66) + textHeight + (textHeight ? scale(window, 12) : 0) + contentHeight + scale(window, 20);
    const RECT card = box(content.left, top, widthOf(content), height);
    addCard(card, glyph, title);
    if (!description.empty()) {
        frame.paragraphs.push_back({box(card.left + inset, card.top + scale(window, 64), widthOf(card) - 2 * inset,
                                        textHeight), description, jsti::chrome::Font::body, true});
    }
    return card.top + scale(window, 66) + textHeight + (textHeight ? scale(window, 12) : 0);
}

void layoutSettings(HWND window, const RECT &content) {
    const int gap = scale(window, 18), row = scale(window, 34), inset = scale(window, 22);
    const bool voice = state.page == voicePage;
    int top = layoutHero(window, content, scale(window, voice ? 132 : 120),
                         voice ? jsti::chrome::Gradient::voice : jsti::chrome::Gradient::settings) + gap;
    const int left = content.left + inset, right = content.right - inset;
    auto label = [&](int identifier, int y) { place(window, identifier, box(left, y + scale(window, 7), scale(window, 180), scale(window, 20))); };
    auto control = [&](int identifier, int y, int width = 0) {
        place(window, identifier, RECT{left + scale(window, 188), y, width ? left + scale(window, 188) + width : right,
                                       y + (identifier == modelID || identifier == microphoneID || identifier == sourceID ||
                                            identifier == modeID || identifier == appearanceID ? scale(window, 240) : row)});
    };
    auto button = [&](int identifier, int y, int width) { place(window, identifier, box(right - width, y, width, row)); };
    switch (state.page) {
    case voicePage: {
        int y = layoutSettingsCard(window, top, content, 0xE767, L"Read aloud",
            L"Choose a recording in History, then read its transcript aloud here or from History. Recording, choosing "
            L"another recording or Stop ends it. Read aloud uses the Deepgram key saved under Transcription.", row);
        place(window, voiceSettingsID, box(left, y, scale(window, 150), row));
        button(readAloudID, y, scale(window, 196));
        place(window, stopPlaybackID, box(right - scale(window, 196) - scale(window, 8) - scale(window, 96), y,
                                          scale(window, 96), row));
        break;
    }
    case generalPage: {
        int y = layoutSettingsCard(window, top, content, 0xE720, L"Microphone", L"", row);
        label(94, y); control(microphoneID, y);
        top = y + row + scale(window, 20) + gap;
        y = layoutSettingsCard(window, top, content, 0xE8C8, L"Output",
            L"Finished text goes back into the app you were in when dictation started, or to the clipboard.", row);
        place(window, textOutputID, box(left, y, scale(window, 170), row));
        top = y + row + scale(window, 20) + gap;
        y = layoutSettingsCard(window, top, content, 0xE790, L"Appearance and automation", L"", 2 * row + scale(window, 12));
        label(appearanceLabelID, y); control(appearanceID, y, scale(window, 220));
        place(window, automationID, RECT{left, y + row + scale(window, 12), right, y + 2 * row + scale(window, 12)});
        break;
    }
    case transcriptionPage: {
        auto shown = [](int identifier) { const auto found = state.wanted.find(identifier);
                                          return found == state.wanted.end() || found->second; };
        const bool source = shown(sourceID), mode = shown(modeID);
        const int rows = 4 + (source ? 1 : 0) + (mode ? 1 : 0);
        int y = layoutSettingsCard(window, top, content, 0xE720, L"Model", L"",
                                   rows * row + (rows - 1) * scale(window, 12) + scale(window, 12));
        if (source) { label(sourceLabelID, y); control(sourceID, y); y += row + scale(window, 12); }
        else place(window, sourceLabelID, box(left, y, 1, 1));
        if (mode) { label(95, y); control(modeID, y); y += row + scale(window, 12); }
        label(90, y); control(modelID, y); y += row + scale(window, 12);
        place(window, modelStatusID, RECT{left, y, right - scale(window, 180), y + row + scale(window, 12)});
        button(modelRefreshID, y, scale(window, 168)); button(localModelsID, y, scale(window, 168));
        y += row + scale(window, 24);
        label(91, y);
        placeField(window, keyID, RECT{left + scale(window, 188), y, right - scale(window, 124), y + row});
        button(saveID, y, scale(window, 112));
        y += row + scale(window, 12);
        place(window, azureID, box(left + scale(window, 188), y, scale(window, 240), row));
        break;
    }
    case postProcessingPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE734, L"Clean-up",
            L"Send finished transcripts to an OpenRouter model to fix punctuation and filler, or follow your own "
            L"instructions. Empty recordings stay empty, and History keeps the original beside the result.", row);
        place(window, processingID, box(left, y, scale(window, 230), row));
        break;
    }
    case profilesPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE77B, L"Per-app profiles",
            L"A profile applies its model, language and clean-up prompt when you dictate into the apps it lists. "
            L"The recording keeps the profile it started with.", row);
        place(window, profilesID, box(left, y, scale(window, 190), row));
        break;
    }
    case keyboardPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE765, L"Shortcut",
            L"The shortcut works while another app is in front. Hold, double-tap or press to toggle, as you choose.",
            row + scale(window, 40));
        place(window, shortcutValueID, RECT{left, y, right, y + scale(window, 28)});
        place(window, shortcutID, box(left, y + scale(window, 40), scale(window, 200), row));
        break;
    }
    case cloudSyncPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE753, L"iCloud",
            L"Sign in with your Apple ID to sync History with your Mac. Only transcripts sync; audio stays on the "
            L"device that recorded it. API keys can be imported from your Mac with its key-sync passphrase.", row);
        place(window, cloudSyncID, box(left, y, scale(window, 220), row));
        break;
    }
    default: break;
    }
}

void layoutAbout(HWND window, const RECT &content) {
    const int inset = scale(window, 22), row = scale(window, 34);
    const std::wstring note = L"Open source under the MIT licence. Your audio goes only to the provider you choose, "
        L"or stays on this PC with an on-device model.";
    int y = layoutSettingsCard(window, content.top, content, 0xE946, L"About", L"", scale(window, 96) + row +
        scale(window, 60));
    frame.icon = box(content.left + inset, y, scale(window, 72), scale(window, 72));
    frame.paragraphs.push_back({box(frame.icon.right + scale(window, 18), y + scale(window, 8), scale(window, 480),
                                    scale(window, 30)), L"Just Speak to It", jsti::chrome::Font::title, false});
    frame.paragraphs.push_back({box(frame.icon.right + scale(window, 18), y + scale(window, 38), scale(window, 480),
                                    scale(window, 22)), pageInfo[aboutPage].subtitle, jsti::chrome::Font::body, true});
    y += scale(window, 88);
    frame.paragraphs.push_back({box(content.left + inset, y, widthOf(content) - 2 * inset, scale(window, 44)), note,
                                jsti::chrome::Font::body, false});
    y += scale(window, 52);
    place(window, githubID, box(content.left + inset, y, scale(window, 150), row));
    place(window, issueID, box(content.left + inset + scale(window, 158), y, scale(window, 150), row));
    place(window, privacyID, box(content.left + inset + scale(window, 316), y, scale(window, 150), row));
}

void layout(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    frame = Frame{};
    const int sidebarWidth = scale(window, 232), headerHeight = scale(window, 64), statusHeight = scale(window, 44);
    const int padding = scale(window, 24);
    frame.sidebar = RECT{0, 0, sidebarWidth, client.bottom};
    frame.header = RECT{sidebarWidth, 0, client.right, headerHeight};
    frame.status = RECT{sidebarWidth, client.bottom - statusHeight, client.right, client.bottom};
    // Sidebar: Speak, then Settings, as on the Mac.
    int y = scale(window, 70);
    frame.speakHeading = box(scale(window, 22), y, sidebarWidth - scale(window, 44), scale(window, 20));
    y += scale(window, 24);
    for (int page = 0; page < pageCount; ++page) {
        if (page == generalPage) {
            y += scale(window, 10);
            frame.settingsHeading = box(scale(window, 22), y, sidebarWidth - scale(window, 44), scale(window, 20));
            y += scale(window, 24);
        }
        place(window, navBaseID + page, box(scale(window, 10), y, sidebarWidth - scale(window, 20), scale(window, 36)));
        y += scale(window, 38);
    }
    // Header: Import and Record on every page but those that carry their own.
    const int buttonTop = (headerHeight - scale(window, 36)) / 2;
    if (state.page != dashboardPage) {
        place(window, recordID, box(client.right - padding - scale(window, 124), buttonTop, scale(window, 124), scale(window, 36)));
    }
    if (state.page != historyPage) {
        // Beside Record, or at the edge where the dashboard's hero carries Record.
        const int right = state.page == dashboardPage ? client.right - padding
                                                      : client.right - padding - scale(window, 124) - scale(window, 10);
        place(window, importID, box(right - scale(window, 140), buttonTop, scale(window, 140), scale(window, 36)));
    }
    place(window, statusID, RECT{sidebarWidth + padding, frame.status.top + scale(window, 12), client.right - padding,
                                 client.bottom - scale(window, 8)});
    const RECT content{sidebarWidth + padding, headerHeight + scale(window, 4), client.right - padding,
                       client.bottom - statusHeight - scale(window, 18)};
    switch (state.page) {
    case dashboardPage: layoutDashboard(window, content); break;
    case historyPage: layoutHistory(window, content); break;
    case aboutPage: layoutAbout(window, content); break;
    default: layoutSettings(window, content); break;
    }
    applyVisibility(window);
    invalidateBackdrop(window);
}

// ------------------------------------------------------------- painting

void paintFrame(HWND window, HDC dc) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    RECT client{};
    GetClientRect(window, &client);
    RECT clip{};
    GetClipBox(dc, &clip);
    auto visible = [&](const RECT &rect) { RECT overlap{}; return IntersectRect(&overlap, &rect, &clip) != FALSE; };
    auto solid = [&](const RECT &rect, COLORREF color) {
        HBRUSH brush = CreateSolidBrush(color);
        FillRect(dc, &rect, brush);
        DeleteObject(brush);
    };
    solid(client, palette.window);
    if (visible(frame.sidebar)) {
        solid(frame.sidebar, palette.sidebar);
        solid(RECT{frame.sidebar.right - 1, 0, frame.sidebar.right, client.bottom}, palette.fieldBorder);
        chrome::brandIcon(dc, box(s(20), s(20), s(28), s(28)));
        chrome::text(dc, L"Just Speak to It", box(s(58), s(20), s(170), s(28)), chrome::Font::title, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, L"Speak", frame.speakHeading, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, L"Settings", frame.settingsHeading, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
    }
    if (visible(frame.header)) {
        const RECT title{frame.header.left + s(24), s(10), frame.header.right - s(300), s(36)};
        chrome::text(dc, pageInfo[state.page].title, title, chrome::Font::pageTitle, dpi, palette.text,
                     DT_LEFT | DT_BOTTOM | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, state.headerSubtitle, RECT{title.left, s(36), title.right, s(56)}, chrome::Font::caption, dpi,
                     palette.secondary, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    }
    solid(RECT{frame.status.left, frame.status.top, frame.status.right, frame.status.top + 1}, palette.fieldBorder);
    if (frame.hero.right > frame.hero.left && visible(frame.hero)) {
        const COLORREF tint = frame.gradient == chrome::Gradient::voice ? chrome::green : chrome::accentDeep;
        chrome::shadow(dc, frame.hero, s(28), tint, s(14));
        chrome::fillGradient(dc, frame.hero, s(28), frame.gradient);
        const int reserved = state.page == dashboardPage ? s(250) : state.page == historyPage ? s(170) : s(28);
        chrome::text(dc, frame.heroTitle, RECT{frame.hero.left + s(26), frame.hero.top + s(20), frame.hero.right - reserved,
                     frame.hero.top + s(58)}, chrome::Font::heroTitle, dpi, RGB(255, 255, 255),
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        chrome::text(dc, frame.heroSubtitle, RECT{frame.hero.left + s(26), frame.hero.top + s(60), frame.hero.right - reserved,
                     frame.hero.top + s(100)}, chrome::Font::heroSubtitle, dpi, RGB(0xFF, 0xF4, 0xEE),
                     DT_LEFT | DT_WORDBREAK | DT_NOPREFIX | DT_END_ELLIPSIS);
        for (const auto &chip : frame.chips) {
            chrome::fillRound(dc, chip.rect, s(18), RGB(255, 255, 255), 44);
            std::wstring upper = chip.label;
            CharUpperBuffW(&upper[0], static_cast<DWORD>(upper.size()));
            chrome::text(dc, upper, RECT{chip.rect.left + s(14), chip.rect.top + s(9), chip.rect.right - s(8),
                         chip.rect.top + s(26)}, chrome::Font::smallBold, dpi, RGB(0xFF, 0xEE, 0xE6),
                         DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        }
    }
    for (const auto &card : frame.cards) {
        if (!visible(card.rect)) continue;
        chrome::shadow(dc, card.rect, s(24), chrome::accentDeep, s(10));
        chrome::fillRound(dc, card.rect, s(24), palette.card);
        chrome::strokeRound(dc, card.rect, s(24), chrome::accentDeep, chrome::dark() ? 70 : 40, 1.0f);
        const RECT tile = box(card.rect.left + s(20), card.rect.top + s(18), s(36), s(36));
        chrome::fillRound(dc, tile, s(12), chrome::accent, chrome::dark() ? 60 : 38);
        chrome::glyph(dc, card.glyph, tile, chrome::dark() ? RGB(0xFF, 0x8A, 0x5C) : chrome::accentDeep, dpi);
        chrome::text(dc, card.title, RECT{tile.right + s(12), tile.top, card.rect.right - s(20), tile.bottom},
                     chrome::Font::title, dpi, palette.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &stat : frame.stats) {
        chrome::fillRound(dc, stat.rect, s(16), chrome::accent, chrome::dark() ? 34 : 22);
        chrome::text(dc, stat.label, RECT{stat.rect.left + s(14), stat.rect.top + s(8), stat.rect.right - s(8),
                     stat.rect.top + s(28)}, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &tile : frame.tiles) {
        chrome::fillRound(dc, tile.rect, s(16), palette.field);
        chrome::strokeRound(dc, tile.rect, s(16), chrome::green, 110, 1.0f);
        chrome::glyph(dc, tile.glyph, box(tile.rect.left + s(8), tile.rect.top + s(6), s(22), s(22)), chrome::accentDeep, dpi);
        chrome::text(dc, tile.title, RECT{tile.rect.left + s(34), tile.rect.top + s(6), tile.rect.right - s(8),
                     tile.rect.top + s(28)}, chrome::Font::bodySemibold, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &field : frame.fields) {
        chrome::fillRound(dc, field, s(10), palette.field);
        chrome::strokeRound(dc, field, s(10), palette.fieldBorder, 255, 1.0f);
    }
    for (const auto &paragraph : frame.paragraphs) {
        chrome::text(dc, paragraph.text, paragraph.rect, paragraph.font, dpi,
                     paragraph.secondary ? palette.secondary : palette.text, DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
    }
    if (frame.icon.right > frame.icon.left) chrome::brandIcon(dc, frame.icon);
}

// The painted window, rendered once per change and copied from: WM_PAINT,
// WM_PRINTCLIENT and every owner-drawn control's background come from it, so
// GDI+ only ever draws on a memory DC with no viewport offset.
struct Backdrop {
    HDC dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    int width = 0, height = 0;
    bool dirty = true;
    void release() {
        if (dc && previous) SelectObject(dc, previous);
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        *this = Backdrop{};
    }
} backdrop;

// Controls draw their own backgrounds from the backdrop, so a new backdrop
// repaints them too.
void invalidateBackdrop(HWND window) {
    backdrop.dirty = true;
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

HDC backdropDC(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    const int width = std::max<int>(client.right, 1), height = std::max<int>(client.bottom, 1);
    if (!backdrop.dc || backdrop.width != width || backdrop.height != height) {
        backdrop.release();
        HDC screen = GetDC(window);
        backdrop.dc = CreateCompatibleDC(screen);
        backdrop.bitmap = CreateCompatibleBitmap(screen, width, height);
        ReleaseDC(window, screen);
        if (!backdrop.dc || !backdrop.bitmap) { backdrop.release(); return nullptr; }
        backdrop.previous = SelectObject(backdrop.dc, backdrop.bitmap);
        backdrop.width = width;
        backdrop.height = height;
        backdrop.dirty = true;
    }
    if (backdrop.dirty) {
        paintFrame(window, backdrop.dc);
        backdrop.dirty = false;
    }
    return backdrop.dc;
}

// Copies what lies behind `control` to (0, 0) of `target`.
void copyBackdrop(HWND window, HDC target, HWND control, int width, int height) {
    const auto found = placed.find(GetDlgCtrlID(control));
    RECT rect{};
    if (found != placed.end()) rect = found->second;
    else {
        GetWindowRect(control, &rect);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&rect), 2);
    }
    HDC source = backdropDC(window);
    if (source) BitBlt(target, 0, 0, width, height, source, rect.left, rect.top, SRCCOPY);
}

// A memory bitmap the size of an owner-drawn item, copied to it when done.
struct Canvas {
    HDC target, dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    RECT item;
    Canvas(HDC target, const RECT &item) : target(target), item(item) {
        dc = CreateCompatibleDC(target);
        bitmap = CreateCompatibleBitmap(target, std::max<int>(widthOf(item), 1), std::max<int>(heightOf(item), 1));
        if (dc && bitmap) previous = SelectObject(dc, bitmap);
    }
    ~Canvas() {
        if (dc && bitmap) BitBlt(target, item.left, item.top, widthOf(item), heightOf(item), dc, 0, 0, SRCCOPY);
        if (previous) SelectObject(dc, previous);
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
    }
    RECT bounds() const { return RECT{0, 0, widthOf(item), heightOf(item)}; }
    bool ready() const { return dc && bitmap; }
};

// ------------------------------------------------------ owner-drawn controls

std::wstring controlText(HWND control) {
    const int length = std::max(GetWindowTextLengthW(control), 0);
    std::wstring value(static_cast<size_t>(length) + 1, 0);
    GetWindowTextW(control, &value[0], length + 1);
    value.resize(static_cast<size_t>(length));
    return value;
}

COLORREF navTint(int page) {
    switch (page) {
    case dashboardPage: return jsti::chrome::lagoon;
    case historyPage: return jsti::chrome::accentDeep;
    case voicePage: return jsti::chrome::green;
    default: return RGB(0xF0, 0x8A, 0x2C);
    }
}

void drawControl(HWND window, const DRAWITEMSTRUCT &item) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    Canvas canvas(item.hDC, item.rcItem);
    if (!canvas.ready()) return;
    HDC dc = canvas.dc;
    RECT rect = canvas.bounds();
    copyBackdrop(window, dc, item.hwndItem, widthOf(rect), heightOf(rect));
    const int identifier = static_cast<int>(item.CtlID);
    const std::wstring label = controlText(item.hwndItem);
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool focused = (item.itemState & ODS_FOCUS) != 0 && (item.itemState & ODS_NOFOCUSRECT) == 0;
    const UINT centred = DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS;
    const Role role = roleOf(window, identifier);
    const int recording = state.displayedRecording;
    switch (role) {
    case Role::nav: {
        const int page = identifier - navBaseID;
        const bool selected = page == state.page;
        if (selected) chrome::fillRound(dc, rect, s(10), chrome::accent, chrome::dark() ? 58 : 40);
        else if (pressed) chrome::fillRound(dc, rect, s(10), palette.text, 20);
        chrome::glyph(dc, pageInfo[page].glyph, box(rect.left + s(8), rect.top, s(28), heightOf(rect)), navTint(page), dpi);
        chrome::text(dc, label, RECT{rect.left + s(42), rect.top, rect.right - s(8), rect.bottom},
                     selected ? chrome::Font::bodySemibold : chrome::Font::body, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::record: {
        const bool live = recording == 1;
        if (disabled) chrome::fillRound(dc, rect, heightOf(rect) / 2, palette.secondary, 90);
        else chrome::fillGradient(dc, rect, heightOf(rect) / 2, live ? chrome::Gradient::recording : chrome::Gradient::record);
        if (pressed) chrome::fillRound(dc, rect, heightOf(rect) / 2, RGB(0, 0, 0), 30);
        const bool large = heightOf(rect) > s(44);
        const std::wstring shown = recording == 1 ? (large ? L"Stop Recording" : L"Stop")
            : recording == 2 ? (large ? L"Cancel Transcription" : L"Cancel") : (large ? L"Start Recording" : L"Record");
        HGDIOBJ previous = SelectObject(dc, chrome::font(chrome::Font::bodySemibold, dpi));
        SIZE extent{};
        GetTextExtentPoint32W(dc, shown.c_str(), static_cast<int>(shown.size()), &extent);
        SelectObject(dc, previous);
        const int icon = s(20), spacing = s(8);
        const int start = rect.left + (widthOf(rect) - icon - spacing - extent.cx) / 2;
        chrome::glyph(dc, recording == 1 ? 0xE71A : 0xE720, box(start, rect.top, icon, heightOf(rect)), RGB(255, 255, 255), dpi);
        chrome::text(dc, shown, RECT{start + icon + spacing, rect.top, rect.right, rect.bottom}, chrome::Font::bodySemibold,
                     dpi, RGB(255, 255, 255), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::primary:
    case Role::button:
    case Role::heroButton: {
        const int radius = s(9);
        COLORREF ink = palette.text;
        if (role == Role::primary) {
            chrome::fillRound(dc, rect, radius, disabled ? chrome::mix(palette.window, chrome::accentDeep, 90) : chrome::accentDeep);
            ink = RGB(255, 255, 255);
        } else if (role == Role::heroButton) {
            chrome::fillRound(dc, rect, radius, RGB(255, 255, 255), disabled ? 30 : 56);
            ink = RGB(255, 255, 255);
        } else {
            chrome::fillRound(dc, rect, radius, palette.field);
            chrome::strokeRound(dc, rect, radius, palette.fieldBorder, 255, 1.0f);
            if (disabled) ink = chrome::mix(palette.field, palette.secondary, 150);
        }
        if (pressed) chrome::fillRound(dc, rect, radius, RGB(0, 0, 0), 26);
        chrome::text(dc, label, RECT{rect.left + s(6), rect.top, rect.right - s(6), rect.bottom}, chrome::Font::bodySemibold,
                     dpi, ink, centred);
        break;
    }
    case Role::toggle: {
        bool on;
        { std::lock_guard<std::mutex> lock(state.mutex); on = state.automationEnabled; }
        const RECT track = box(rect.right - s(46), rect.top + (heightOf(rect) - s(24)) / 2, s(44), s(24));
        chrome::fillRound(dc, track, s(12), on ? chrome::accentDeep : palette.fieldBorder);
        const RECT knob = box(on ? track.right - s(21) : track.left + s(3), track.top + s(3), s(18), s(18));
        chrome::fillRound(dc, knob, s(9), RGB(255, 255, 255));
        chrome::text(dc, label, RECT{rect.left, rect.top, track.left - s(12), rect.bottom}, chrome::Font::body, dpi,
                     disabled ? palette.secondary : palette.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::link: break;
    case Role::chipValue:
        chrome::text(dc, label, rect, chrome::Font::chipValue, dpi, RGB(255, 255, 255),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::statValue:
        chrome::text(dc, label, rect, chrome::Font::chipValue, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::tileValue:
        chrome::text(dc, label, rect, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::value:
        chrome::text(dc, label, rect, chrome::Font::title, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::caption: {
        // The shortcut hint repeats the card's "Transcript" title; show only the shortcut.
        std::wstring shown = label;
        const std::wstring prefix = L"Transcript \u2014 ";
        if (identifier == transcriptLabelID && shown.compare(0, prefix.size(), prefix) == 0) shown.erase(0, prefix.size());
        chrome::text(dc, shown, rect, chrome::Font::caption, dpi, palette.secondary,
                     (identifier == transcriptLabelID ? DT_RIGHT | DT_SINGLELINE : DT_LEFT | DT_WORDBREAK) |
                     DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    }
    case Role::status:
        chrome::text(dc, label, rect, chrome::Font::body, dpi, palette.text, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::label:
    case Role::detail:
        chrome::text(dc, label, rect, chrome::Font::bodySemibold, dpi, palette.text, DT_LEFT | DT_WORDBREAK);
        return;
    }
    if (focused) {
        RECT ring = rect;
        chrome::strokeRound(dc, ring, role == Role::record ? heightOf(rect) / 2 : s(10), chrome::accent, 220, 2.0f);
    }
}

// One History card: badges, the preview and the models line.
void drawHistoryItem(HWND window, const DRAWITEMSTRUCT &item) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    Canvas canvas(item.hDC, item.rcItem);
    if (!canvas.ready()) return;
    HDC dc = canvas.dc;
    RECT area = canvas.bounds();
    HBRUSH background = CreateSolidBrush(palette.window);
    FillRect(dc, &area, background);
    DeleteObject(background);
    if (item.itemID == static_cast<UINT>(-1) || item.itemID >= state.displayedHistory.size()) return;
    const HistoryRow &row = state.displayedHistory[item.itemID];
    RECT card{area.left + s(2), area.top + s(5), area.right - s(4), area.bottom - s(5)};
    const bool selected = (item.itemState & ODS_SELECTED) != 0;
    chrome::fillRound(dc, card, s(20), palette.card);
    const COLORREF edge = row.tone == 1 ? chrome::orange : chrome::accentDeep;
    chrome::strokeRound(dc, card, s(20), edge, selected ? 230 : (row.tone == 1 ? 120 : 50), selected ? 2.0f : 1.0f);
    int x = card.left + s(16);
    const int top = card.top + s(12);
    auto badge = [&](const std::wstring &title, const std::wstring &value, COLORREF tint) {
        if (value.empty()) return;
        HGDIOBJ previous = SelectObject(dc, chrome::font(chrome::Font::caption, dpi));
        SIZE extent{};
        GetTextExtentPoint32W(dc, value.c_str(), static_cast<int>(value.size()), &extent);
        SelectObject(dc, previous);
        const int width = std::min<int>(std::max<int>(extent.cx, s(52)) + s(20), card.right - s(16) - x);
        if (width < s(48)) return;
        const RECT shape = box(x, top, width, s(40));
        chrome::fillRound(dc, shape, s(10), tint, chrome::dark() ? 52 : 32);
        std::wstring upper = title;
        CharUpperBuffW(&upper[0], static_cast<DWORD>(upper.size()));
        chrome::text(dc, upper, RECT{shape.left + s(10), shape.top + s(4), shape.right - s(6), shape.top + s(18)},
                     chrome::Font::smallBold, dpi, tint, DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, value, RECT{shape.left + s(10), shape.top + s(18), shape.right - s(6), shape.bottom - s(3)},
                     chrome::Font::caption, dpi, tint, DT_LEFT | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        x = shape.right + s(8);
    };
    badge(L"Created", row.created, chrome::blue);
    badge(L"Audio", row.audio, chrome::blue);
    badge(L"Cost", row.cost, chrome::green);
    badge(L"Context", row.context, chrome::lagoon);
    if (row.tone == 1) badge(L"Error", L"Needs attention", chrome::orange);
    else if (row.tone == 2) badge(L"Status", L"Not transcribed", chrome::orange);
    const RECT preview{card.left + s(16), top + s(48), card.right - s(16), card.bottom - s(28)};
    chrome::text(dc, row.preview.empty() ? row.detail : row.preview, preview, chrome::Font::body, dpi, palette.text,
                 DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX | DT_EDITCONTROL);
    chrome::glyph(dc, 0xE713, box(card.left + s(14), card.bottom - s(26), s(18), s(18)), palette.secondary, dpi);
    chrome::text(dc, row.models.empty() ? row.title : row.models, RECT{card.left + s(36), card.bottom - s(28),
                 card.right - s(16), card.bottom - s(8)}, chrome::Font::caption, dpi, palette.secondary,
                 DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
}

// ------------------------------------------------------------ appearance

HBRUSH brushFor(COLORREF color) {
    static std::unordered_map<COLORREF, HBRUSH> brushes;
    const auto found = brushes.find(color);
    if (found != brushes.end()) return found->second;
    HBRUSH created = CreateSolidBrush(color);
    brushes[color] = created;
    return created;
}

// Dark or light native controls, title bar and repaint, after the choice or
// Windows' own setting changes.
void applyTheme(HWND window) {
    const BOOL dark = jsti::chrome::dark() ? TRUE : FALSE;
    constexpr DWORD immersiveDarkMode = 20;
    DwmSetWindowAttribute(window, immersiveDarkMode, &dark, sizeof(dark));
    for (HWND control : state.controls) {
        wchar_t kind[16] = {};
        GetClassNameW(control, kind, 16);
        if (_wcsicmp(kind, L"COMBOBOX") == 0) SetWindowTheme(control, dark ? L"DarkMode_CFD" : nullptr, nullptr);
        else if (_wcsicmp(kind, L"EDIT") == 0 || _wcsicmp(kind, L"LISTBOX") == 0) {
            SetWindowTheme(control, dark ? L"DarkMode_Explorer" : L"Explorer", nullptr);
        }
    }
    backdrop.dirty = true;
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_FRAME);
    jsti::hud::refresh();
}

void refreshFont(HWND window) {
    const UINT dpi = GetDpiForWindow(window);
    for (HWND control : state.controls) {
        const HFONT chosen = GetDlgCtrlID(control) == transcriptID
            ? jsti::chrome::font(jsti::chrome::Font::mono, dpi) : jsti::chrome::font(jsti::chrome::Font::body, dpi);
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(chosen), TRUE);
    }
    SendDlgItemMessageW(window, historyID, LB_SETITEMHEIGHT, 0, scale(window, 132));
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

void showPage(HWND window, int page) {
    if (page < 0 || page >= pageCount) return;
    const int previous = state.page;
    state.page = page;
    // A control on the page being left keeps no keyboard focus.
    HWND focus = GetFocus();
    layout(window);
    if (focus && IsChild(window, focus) && !IsWindowVisible(focus)) SetFocus(GetDlgItem(window, navBaseID + page));
    for (int index : {previous, page}) InvalidateRect(GetDlgItem(window, navBaseID + index), nullptr, TRUE);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

// The dashboard's Setup card and the header subtitle echo the settings.
void refreshSetup(HWND window) {
    auto comboText = [&](int identifier) {
        HWND combo = GetDlgItem(window, identifier);
        const LRESULT index = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (index == CB_ERR) return std::wstring();
        const LRESULT length = SendMessageW(combo, CB_GETLBTEXTLEN, static_cast<WPARAM>(index), 0);
        if (length == CB_ERR) return std::wstring();
        std::wstring text(static_cast<size_t>(length) + 1, 0);
        SendMessageW(combo, CB_GETLBTEXT, static_cast<WPARAM>(index), reinterpret_cast<LPARAM>(&text[0]));
        text.resize(static_cast<size_t>(length));
        return text;
    };
    auto set = [&](int identifier, const std::wstring &text) {
        if (controlText(GetDlgItem(window, identifier)) != text) SetDlgItemTextW(window, identifier, text.c_str());
    };
    const std::wstring model = comboText(modelID);
    set(setupMicrophoneID, comboText(microphoneID));
    set(setupModelID, model.empty() ? L"No model selected" : model);
    std::wstring shortcut = jsti_hotkey_label();
    const std::wstring prefix = L"Transcript — ";
    if (shortcut.compare(0, prefix.size(), prefix) == 0) shortcut.erase(0, prefix.size());
    set(setupShortcutID, shortcut);
    set(shortcutValueID, shortcut);
    int method = 0, insertion = 0, restore = 1;
    std::wstring output = L"Paste into the app you started in";
    if (jsti_window_text_output(&method, &insertion, &restore) == 0) {
        output = method == JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY ? L"Copy to the clipboard"
            : method == JSTI_TEXT_OUTPUT_DIRECT_ONLY ? L"Type into the field only" : L"Smart: insert, then paste";
    }
    set(setupOutputID, output);
    if (state.headerSubtitle != model) {
        state.headerSubtitle = model;
        invalidateBackdrop(window);
    }
}

bool createControls(HWND window) {
    auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int identifier) {
        const bool field = wcscmp(kind, L"EDIT") == 0;
        if (wcscmp(kind, L"STATIC") == 0) style = SS_OWNERDRAW | SS_NOPREFIX;
        if (wcscmp(kind, L"BUTTON") == 0 && (style & BS_TYPEMASK) == BS_PUSHBUTTON) style = (style & ~BS_TYPEMASK) | BS_OWNERDRAW;
        HWND control = CreateWindowExW(0, kind, label, WS_CHILD | WS_VISIBLE | style | (field ? 0 : 0), 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(identifier)), GetModuleHandleW(nullptr), nullptr);
        if (control) state.controls.push_back(control);
        return control != nullptr;
    };
    bool okay = true;
    for (int page = 0; page < pageCount && okay; ++page) {
        okay = add(L"BUTTON", pageInfo[page].title, BS_PUSHBUTTON | WS_TABSTOP, navBaseID + page);
    }
    // Each label immediately precedes its control so assistive technology and
    // Alt mnemonics resolve the intended target. Labels are owner-drawn static
    // controls, so their text stays the accessible name.
    okay = okay && add(L"BUTTON", L"&Record", BS_PUSHBUTTON | WS_TABSTOP, recordID) &&
        add(L"BUTTON", L"&Import audio", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"STATIC", L"&Find in history", 0, searchLabelID) &&
        add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, searchID) &&
        add(L"BUTTON", L"C&lear", BS_PUSHBUTTON | WS_TABSTOP, clearSearchID) &&
        add(L"STATIC", L"&History", 0, 93) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_VSCROLL | WS_TABSTOP,
            historyID) &&
        add(L"STATIC", L"Your saved recordings will appear here.", 0, historyDetailID) &&
        add(L"STATIC", L"Transcript &version", 0, variantLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, variantID) &&
        add(L"BUTTON", L"Retr&y", BS_PUSHBUTTON | WS_TABSTOP, retryID) &&
        add(L"BUTTON", L"&Export text", BS_PUSHBUTTON | WS_TABSTOP, exportID) &&
        add(L"BUTTON", L"&Open audio", BS_PUSHBUTTON | WS_TABSTOP, openAudioID) &&
        add(L"BUTTON", L"Rea&d aloud", BS_PUSHBUTTON | WS_TABSTOP, readAloudID) &&
        // The label carries the mnemonic and precedes Play/Pause, so Alt+B
        // and assistive technology reach the playback controls.
        add(L"STATIC", L"Play&back", 0, playbackLabelID) &&
        add(L"STATIC", playbackIdleText, 0, playbackTimeID) &&
        add(L"BUTTON", L"Play", BS_PUSHBUTTON | WS_TABSTOP, playPauseID) &&
        add(L"BUTTON", L"Stop", BS_PUSHBUTTON | WS_TABSTOP, stopPlaybackID) &&
        add(L"BUTTON", L"Choose &voice…", BS_PUSHBUTTON | WS_TABSTOP, voiceSettingsID) &&
        add(L"BUTTON", L"Edit app &profiles…", BS_PUSHBUTTON | WS_TABSTOP, profilesID) &&
        add(L"STATIC", L"&Source", 0, sourceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, sourceID) &&
        add(L"STATIC", L"&Mode", 0, 95) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, modeID) &&
        add(L"STATIC", L"", 0, shortcutValueID) &&
        add(L"BUTTON", L"Change &keyboard shortcut…", BS_PUSHBUTTON | WS_TABSTOP, shortcutID) &&
        add(L"STATIC", L"&Transcription model", 0, 90) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"BUTTON", L"Configure &post-processing…", BS_PUSHBUTTON | WS_TABSTOP, processingID) &&
        add(L"STATIC", L"OpenRouter discovery not loaded.", 0, modelStatusID) &&
        add(L"BUTTON", L"Refresh &models", BS_PUSHBUTTON | WS_TABSTOP, modelRefreshID) &&
        add(L"BUTTON", L"Local mo&dels…", BS_PUSHBUTTON | WS_TABSTOP, localModelsID) &&
        add(L"STATIC", L"&API key (Windows Credential Manager)", 0, 91) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"BUTTON", L"A&zure Speech resource…", BS_PUSHBUTTON | WS_TABSTOP, azureID) &&
        add(L"STATIC", L"&Microphone", 0, 94) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, microphoneID) &&
        add(L"BUTTON", L"Text o&utput…", BS_PUSHBUTTON | WS_TABSTOP, textOutputID) &&
        add(L"STATIC", L"&Theme", 0, appearanceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, appearanceID) &&
        add(L"BUTTON", L"Allow &automation (speak command and MCP)", BS_PUSHBUTTON | WS_TABSTOP, automationID) &&
        add(L"BUTTON", L"i&Cloud sync settings…", BS_PUSHBUTTON | WS_TABSTOP, cloudSyncID) &&
        add(L"BUTTON", L"View on &GitHub", BS_PUSHBUTTON | WS_TABSTOP, githubID) &&
        add(L"BUTTON", L"Report an iss&ue", BS_PUSHBUTTON | WS_TABSTOP, issueID) &&
        add(L"BUTTON", L"Pri&vacy policy", BS_PUSHBUTTON | WS_TABSTOP, privacyID) &&
        add(L"STATIC", jsti_hotkey_label().c_str(), 0, transcriptLabelID) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, transcriptID) &&
        add(L"BUTTON", L"&Copy transcript", BS_PUSHBUTTON | WS_TABSTOP, copyID);
    for (int identifier : {chipSessionsID, chipTimeID, chipSpendID, insightSessionsID, insightTimeID, insightAverageID,
                           insightSpendID, historySessionsID, historyErrorsID, historyAverageID, historySpendID,
                           setupMicrophoneID, setupModelID, setupShortcutID, setupOutputID}) {
        okay = okay && add(L"STATIC", L"—", 0, identifier);
    }
    okay = okay && add(L"STATIC", L"Ready. Choose a model and save its API key to begin.", 0, statusID);
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
    SendDlgItemMessageW(window, searchID, EM_SETCUEBANNER, TRUE,
                        reinterpret_cast<LPARAM>(L"Search transcripts, models and profiles"));
    SendDlgItemMessageW(window, transcriptID, EM_LIMITTEXT, 4 * 1024 * 1024, 0);
    refreshFont(window);
    if (SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Remote (API providers)")) < 0 ||
        SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Local (on this PC)")) < 0 ||
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Batch")) < 0 ||
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Live")) < 0 ||
        SendDlgItemMessageW(window, variantID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Processed transcript")) < 0 ||
        SendDlgItemMessageW(window, variantID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Original transcript")) < 0 ||
        SendDlgItemMessageW(window, appearanceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Follow Windows")) < 0 ||
        SendDlgItemMessageW(window, appearanceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Light")) < 0 ||
        SendDlgItemMessageW(window, appearanceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Dark")) < 0 ||
        !populateModels(window)) return false;
    SendDlgItemMessageW(window, appearanceID, CB_SETCURSEL, jsti::chrome::appearance(), 0);
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
    applyTheme(window);
    refreshSetup(window);
    layout(window);
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

// Settings that were menu commands follow their dialogs' idle rules; the
// automation switch shows the state the host reported.
void updateSettingsButtons(HWND window, int recording) {
    EnableWindow(GetDlgItem(window, voiceSettingsID), recording == 0 && jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, localModelsID), recording == 0 && jsti_local_models_available());
    EnableWindow(GetDlgItem(window, cloudSyncID), recording == 0 && jsti_cloud_sync_available());
    EnableWindow(GetDlgItem(window, azureID), recording == 0 && jsti_azure_resource_available());
    bool automation;
    { std::lock_guard<std::mutex> lock(state.mutex); automation = state.automationEnabled; }
    HWND toggle = GetDlgItem(window, automationID);
    if ((GetWindowLongPtrW(toggle, GWLP_USERDATA) != 0) != automation) {
        SetWindowLongPtrW(toggle, GWLP_USERDATA, automation ? 1 : 0);
        InvalidateRect(toggle, nullptr, FALSE);
    }
}

// History totals from jsti_window_set_insights, shown only when they change.
void applyInsights(HWND window) {
    std::wstring values[2][5];
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.insightsChanged) return;
        state.insightsChanged = false;
        for (int group = 0; group < 2; ++group) for (int index = 0; index < 5; ++index) values[group][index] = state.insights[group][index];
    }
    const std::pair<int, const std::wstring *> targets[] = {
        {chipSessionsID, &values[0][0]}, {chipTimeID, &values[0][2]}, {chipSpendID, &values[0][4]},
        {insightSessionsID, &values[0][0]}, {insightTimeID, &values[0][2]}, {insightAverageID, &values[0][3]},
        {insightSpendID, &values[0][4]}, {historySessionsID, &values[1][0]}, {historyErrorsID, &values[1][1]},
        {historyAverageID, &values[1][3]}, {historySpendID, &values[1][4]}};
    for (const auto &target : targets) SetDlgItemTextW(window, target.first, target.second->c_str());
    // The notification area's menu shows the same totals as the Mac's menu bar extra.
    std::wstring summary;
    if (values[0][0] == L"0") {
        summary = L"No sessions yet";
    } else if (!values[0][0].empty()) {
        summary = values[0][0] + (values[0][0] == L"1" ? L" session" : L" sessions");
        if (!values[0][2].empty()) summary += L" · " + values[0][2];
        if (!values[0][4].empty()) summary += L" · " + values[0][4];
    }
    state.traySummary = summary;
    jsti::tray::setState(state.displayedRecording, state.traySummary);
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
    applyInsights(window);

    SetDlgItemTextW(window, recordID, recording == 1 ? L"&Stop recording" : (recording == 2 ? L"&Cancel transcription" : L"&Record"));
    EnableWindow(GetDlgItem(window, recordID), TRUE);
    if (state.displayedRecording != recording) {
        state.displayedRecording = recording;
        InvalidateRect(GetDlgItem(window, recordID), nullptr, FALSE);
        jsti::tray::setState(recording, state.traySummary);
    }
    for (int id : {keyID, saveID, microphoneID, profilesID}) EnableWindow(GetDlgItem(window, id), recording == 0);
    updateModelAvailability(window, recording);
    EnableWindow(GetDlgItem(window, processingID), recording == 0 && jsti_postprocessing_available());
    EnableWindow(GetDlgItem(window, textOutputID), recording == 0 && jsti_text_output_available());
    EnableWindow(GetDlgItem(window, shortcutID), recording == 0 && jsti_hotkey_available());
    updateSettingsButtons(window, recording);
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
    refreshSetup(window);
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

// The screenshot tour: every page, then the dashboard and History in dark
// mode, then the dashboard while recording. Each step is shown, drawn, then
// saved as NN-name.bmp beside the others; the window closes afterwards.
constexpr int tourSteps = pageCount + 5;

std::string tourName(int step) {
    if (step < pageCount) return pageInfo[step].name;
    const char *const extra[] = {"dashboard-dark", "history-dark", "dashboard-recording", "hud-recording",
                                 "hud-completed"};
    return extra[step - pageCount];
}

void tourShow(HWND window, int step) {
    if (step < pageCount) {
        showPage(window, step);
    } else if (step == pageCount) {
        jsti::chrome::setAppearance(2);
        SendDlgItemMessageW(window, appearanceID, CB_SETCURSEL, 2, 0);
        applyTheme(window);
        showPage(window, dashboardPage);
    } else if (step == pageCount + 1) {
        showPage(window, historyPage);
    } else if (step == pageCount + 3) {
        jsti::hud::stage(1, L"Recording", L"Capturing audio",
                         L"Could we move the catch-up to Friday? That gives us a little more time");
        jsti::hud::apply();
    } else if (step == pageCount + 4) {
        jsti::hud::stage(5, L"Completed", L"Saved. Inserted into the original text field.", L"");
        jsti::hud::apply();
    } else {
        // Late, because it replaces the displayed transcript.
        state.displayedRecording = 1;
        SetDlgItemTextW(window, transcriptID, L"Could we move the catch-up to Friday? That gives us a little");
        SetDlgItemTextW(window, statusID, L"Recording… Press Ctrl+Alt+Space again to stop.");
        showPage(window, dashboardPage);
    }
    UpdateWindow(window);
    SetTimer(window, tourTimerID, 700, nullptr);
}

void tourStep(HWND window) {
    if (state.tourStep < 0 || state.tourStep >= tourSteps) return;
    char name[64];
    snprintf(name, sizeof name, "%02d-%s.bmp", state.tourStep + 1, tourName(state.tourStep).c_str());
    const std::string path = jsti::utf8(state.tourDirectory) + "\\" + name;
    char error[512] = {};
    std::string hudError;
    std::wstring widePath;
    if (state.tourStep >= pageCount + 3) {
        // The HUD is its own layered window; it is drawn straight to the file.
        if (!jsti::wide(path.c_str(), widePath) || !jsti::hud::saveSnapshot(widePath, hudError)) {
            emit(window, JSTI_EVENT_ERROR, hudError.empty() ? "The HUD snapshot path is invalid." : hudError.c_str());
        }
    } else if (jsti_window_save_snapshot(path.c_str(), error, sizeof error) != 0) {
        emit(window, JSTI_EVENT_ERROR, error);
    }
    ++state.tourStep;
    if (state.tourStep < tourSteps) tourShow(window, state.tourStep);
    else PostMessageW(window, WM_CLOSE, 0, 0);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_CREATE:
        return createControls(window) ? 0 : -1;
    case WM_GETMINMAXINFO: {
        auto info = reinterpret_cast<MINMAXINFO *>(lparam);
        info->ptMinTrackSize = {minimumWindowWidth(window), minimumWindowHeight(window)};
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
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC target = BeginPaint(window, &paint);
        HDC source = backdropDC(window);
        if (source) {
            BitBlt(target, paint.rcPaint.left, paint.rcPaint.top, paint.rcPaint.right - paint.rcPaint.left,
                   paint.rcPaint.bottom - paint.rcPaint.top, source, paint.rcPaint.left, paint.rcPaint.top, SRCCOPY);
        }
        EndPaint(window, &paint);
        return 0;
    }
    case WM_PRINTCLIENT: {
        // The client belongs at the DC's device origin. A WM_PRINT caller may
        // have moved the viewport so child windows land at their window-relative
        // offsets (the snapshot does), and Windows passes that DC on unchanged.
        HDC target = reinterpret_cast<HDC>(wparam);
        HDC source = backdropDC(window);
        POINT origin{};
        GetViewportOrgEx(target, &origin);
        if (source) BitBlt(target, -origin.x, -origin.y, backdrop.width, backdrop.height, source, 0, 0, SRCCOPY);
        return 0;
    }
    case WM_MEASUREITEM: {
        auto item = reinterpret_cast<MEASUREITEMSTRUCT *>(lparam);
        if (item->CtlType == ODT_LISTBOX) item->itemHeight = static_cast<UINT>(scale(window, 132));
        return TRUE;
    }
    case WM_DRAWITEM: {
        const auto &item = *reinterpret_cast<const DRAWITEMSTRUCT *>(lparam);
        if (item.CtlType == ODT_LISTBOX) drawHistoryItem(window, item);
        else drawControl(window, item);
        return TRUE;
    }
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORLISTBOX: {
        // Edits and the read-only transcript sit on painted fields; the
        // History list and drop-downs on the window's surface.
        const auto &palette = jsti::chrome::palette();
        HDC dc = reinterpret_cast<HDC>(wparam);
        const int identifier = GetDlgCtrlID(reinterpret_cast<HWND>(lparam));
        const COLORREF surface = message == WM_CTLCOLORLISTBOX && identifier == historyID ? palette.window : palette.field;
        SetTextColor(dc, palette.text);
        SetBkColor(dc, surface);
        return reinterpret_cast<LRESULT>(brushFor(surface));
    }
    case WM_SETTINGCHANGE:
        if (lparam && jsti::chrome::appearance() == 0 &&
            wcscmp(reinterpret_cast<const wchar_t *>(lparam), L"ImmersiveColorSet") == 0) applyTheme(window);
        break;
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
        if (wparam == tourTimerID) { KillTimer(window, tourTimerID); tourStep(window); return 0; }
        if (jsti_hotkey_message(window, message, wparam)) return 0;
        break;
    case tourMessage: {
        std::unique_ptr<std::wstring> directory(reinterpret_cast<std::wstring *>(lparam));
        if (!directory || state.tourStep >= 0) return 0;
        state.tourDirectory = *directory;
        state.tourStep = 0;
        tourShow(window, 0);
        return 0;
    }
    case appearanceMessage:
        SendDlgItemMessageW(window, appearanceID, CB_SETCURSEL, jsti::chrome::appearance(), 0);
        applyTheme(window);
        return 0;
    case pageMessage:
        showPage(window, static_cast<int>(wparam));
        return 0;
    case hudMessage:
        jsti::hud::apply();
        return 0;
    case jsti::tray::commandMessage:
        trayCommand(window, static_cast<UINT>(wparam));
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) >= navBaseID && LOWORD(wparam) < navBaseID + pageCount) {
            if (HIWORD(wparam) == BN_CLICKED) showPage(window, LOWORD(wparam) - navBaseID);
            return 0;
        }
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
        case azureID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, azureID) && IsWindowEnabled(window)) {
                jsti_show_azure_resource_settings(window);
            }
            return 0;
        case cloudSyncID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, cloudSyncID) && IsWindowEnabled(window)) {
                jsti_show_cloud_sync_settings(window);
            }
            return 0;
        case automationID: {
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            bool enabled;
            { std::lock_guard<std::mutex> lock(state.mutex); enabled = state.automationEnabled; }
            emit(window, JSTI_EVENT_AUTOMATION_TOGGLED, enabled ? "0" : "1");
            return 0;
        }
        case githubID: case issueID: case privacyID: {
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            const wchar_t *address = LOWORD(wparam) == githubID ? L"https://github.com/crmitchelmore/justspeaktoit"
                : LOWORD(wparam) == issueID ? L"https://github.com/crmitchelmore/justspeaktoit/issues/new"
                : L"https://justspeaktoit.com/privacy";
            ShellExecuteW(window, L"open", address, nullptr, nullptr, SW_SHOWNORMAL);
            return 0;
        }
        case appearanceID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, appearanceID, CB_GETCURSEL, 0, 0);
                if (chosen < 0 || chosen > 2) return 0;
                jsti::chrome::setAppearance(static_cast<int>(chosen));
                applyTheme(window);
                const char value[2] = {static_cast<char>('0' + chosen), 0};
                emit(window, JSTI_EVENT_APPEARANCE, value);
            }
            return 0;
        case textOutputID:
            // Only while idle and not already behind another modal editor.
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, textOutputID) && IsWindowEnabled(window)) {
                jsti_show_text_output(window);
                refreshSetup(window);
            }
            return 0;
        case shortcutID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, shortcutID) && IsWindowEnabled(window)) {
                jsti_show_hotkey_settings(window);
                SetDlgItemTextW(window, transcriptLabelID, jsti_hotkey_label().c_str());
                refreshSetup(window);
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
                refreshSetup(window);
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
                refreshSetup(window);
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
                refreshSetup(window);
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
                refreshSetup(window);
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
        jsti::tray::remove();
        backdrop.release();
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

namespace {
// Common Controls 6 gives the native edits, lists and drop-downs the current
// Windows look. The executable carries no manifest, so an activation context
// is created from one in a private temporary file for this thread.
ULONG_PTR activateVisualStyles() {
    static const char manifest[] =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\"><dependency>"
        "<dependentAssembly><assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" "
        "version=\"6.0.0.0\" processorArchitecture=\"*\" publicKeyToken=\"6595b64144ccf1df\" language=\"*\"/>"
        "</dependentAssembly></dependency></assembly>";
    wchar_t folder[MAX_PATH + 1] = {};
    const DWORD length = GetTempPathW(MAX_PATH, folder);
    if (length == 0 || length > MAX_PATH) return 0;
    wchar_t unique[40] = {};
    GUID identifier{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, unique, 40)) return 0;
    const std::wstring path = std::wstring(folder) + L"JustSpeakToIt-" + unique + L".manifest";
    std::string failure;
    HANDLE file = jsti::createPrivateFileHandle(jsti::utf8(path).c_str(), failure);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD written = 0;
    const bool saved = WriteFile(file, manifest, sizeof(manifest) - 1, &written, nullptr) &&
        written == sizeof(manifest) - 1;
    CloseHandle(file);
    ULONG_PTR cookie = 0;
    if (saved) {
        ACTCTXW context{};
        context.cbSize = sizeof(context);
        context.lpSource = path.c_str();
        HANDLE activation = CreateActCtxW(&context);
        if (activation != INVALID_HANDLE_VALUE) {
            if (!ActivateActCtx(activation, &cookie)) cookie = 0;
            ReleaseActCtx(activation);
        }
    }
    DeleteFileW(path.c_str());
    // Controls created from here on load Common Controls 6.
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);
    return cookie;
}

// The app icon at `size` pixels, drawn from the brand geometry.
// `recording` adds a red dot, as the Mac's menu bar icon shows while recording.
HICON brandIcon(int size, bool recording = false) {
    if (size <= 0 || !jsti::chrome::startup()) return nullptr;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = nullptr;
    HDC screen = GetDC(nullptr);
    HBITMAP colour = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    ReleaseDC(nullptr, screen);
    if (!colour || !pixels) return nullptr;
    std::memset(pixels, 0, static_cast<size_t>(size) * size * 4);
    HDC dc = CreateCompatibleDC(nullptr);
    HGDIOBJ previous = SelectObject(dc, colour);
    jsti::chrome::brandIcon(dc, RECT{0, 0, size, size});
    if (recording) {
        const int dot = std::max(6, size * 7 / 16);
        jsti::chrome::fillRound(dc, RECT{size - dot, size - dot, size, size}, dot / 2, RGB(0xFF, 0xFF, 0xFF));
        jsti::chrome::fillRound(dc, RECT{size - dot + 1, size - dot + 1, size - 1, size - 1}, dot / 2 - 1,
                                jsti::chrome::red);
    }
    SelectObject(dc, previous);
    DeleteDC(dc);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO parts{TRUE, 0, 0, mask, colour};
    HICON icon = CreateIconIndirect(&parts);
    DeleteObject(mask);
    DeleteObject(colour);
    return icon;
}
} // namespace

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
    const ULONG_PTR visualStyles = activateVisualStyles();
    jsti::chrome::startup();
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItWindows";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = nullptr;
    HICON icon = brandIcon(GetSystemMetrics(SM_CXICON)), smallIcon = brandIcon(GetSystemMetrics(SM_CXSMICON));
    HICON recordingIcon = brandIcon(GetSystemMetrics(SM_CXSMICON), true);
    type.hIcon = icon ? icon : LoadIconW(nullptr, IDI_APPLICATION);
    const ATOM registered = RegisterClassW(&type);
    HWND window = registered ? CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Just Speak to It", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
        1180, 820, nullptr, nullptr, instance, nullptr) : nullptr;
    if (window && smallIcon) SendMessageW(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(smallIcon));
    int outcome = 0;
    if (!window) outcome = jsti::fail(jsti::systemError("Creating native desktop window"), error, capacity);
    else {
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = window; }
        ShowWindow(window, SW_SHOWDEFAULT);
        UpdateWindow(window);
        // Optional: without a notification area the app works the same.
        jsti::tray::add(window, smallIcon ? smallIcon : type.hIcon, recordingIcon);
        emit(window, JSTI_EVENT_READY);
        std::string shortcutFailure;
        if (IsWindow(window) && !jsti_hotkey_start(window, shortcutFailure)) showFailure(window, shortcutFailure);
        MSG message{};
        BOOL result;
        while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
            // Ctrl+1 to Ctrl+0 open the pages in sidebar order, as the Mac's
            // Command shortcuts do.
            if (message.message == WM_KEYDOWN && (GetKeyState(VK_CONTROL) & 0x8000) &&
                !(GetKeyState(VK_MENU) & 0x8000) && message.wParam >= '0' && message.wParam <= '9' &&
                (message.hwnd == window || IsChild(window, message.hwnd)) && IsWindowEnabled(window)) {
                const int digit = static_cast<int>(message.wParam - '0');
                showPage(window, digit == 0 ? pageCount - 1 : digit - 1);
                continue;
            }
            if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        }
        if (result < 0) {
            outcome = jsti::fail(jsti::systemError("Reading desktop messages"), error, capacity);
            DestroyWindow(window);
        }
    }
    jsti::hud::destroy();
    state.font = nullptr;
    state.controls.clear(); state.callback = nullptr; state.context = nullptr;
    if (icon) DestroyIcon(icon);
    if (smallIcon) DestroyIcon(smallIcon);
    if (recordingIcon) DestroyIcon(recordingIcon);
    if (visualStyles) DeactivateActCtx(0, visualStyles);
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

int jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible) {
    if (!all || !visible) return -1;
    try {
        std::wstring values[2][5];
        const JSTIInsights *groups[2] = {all, visible};
        for (int group = 0; group < 2; ++group) {
            const char *fields[5] = {groups[group]->sessions, groups[group]->errors, groups[group]->recording_time,
                                     groups[group]->average_length, groups[group]->spend};
            for (int index = 0; index < 5; ++index) {
                if (!fields[index] || !jsti::wide(fields[index], values[group][index]) ||
                    values[group][index].size() > 64) return -1;
            }
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        for (int group = 0; group < 2; ++group) {
            for (int index = 0; index < 5; ++index) state.insights[group][index] = std::move(values[group][index]);
        }
        state.insightsChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_hud(int phase, const char *headline, const char *subheadline, const char *live_text) {
    try {
        std::wstring title, detail, live;
        if (!jsti::wide(headline ? headline : "", title) || !jsti::wide(subheadline ? subheadline : "", detail) ||
            !jsti::wide(live_text ? live_text : "", live) ||
            !jsti::hud::stage(phase, std::move(title), std::move(detail), std::move(live))) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        return state.window && PostMessageW(state.window, hudMessage, 0, 0) ? 0 : -1;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_appearance(int appearance) {
    if (appearance < 0 || appearance > 2) return -1;
    jsti::chrome::setAppearance(appearance);
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, appearanceMessage, 0, 0);
    return 0;
}

int jsti_window_show_page(int page) {
    if (page < 0 || page >= pageCount) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.window && PostMessageW(state.window, pageMessage, static_cast<WPARAM>(page), 0) ? 0 : -1;
}

int jsti_window_screenshot_tour(const char *directory, char *error, size_t capacity) {
    std::wstring folder;
    if (!directory || !jsti::wide(directory, folder) || folder.empty()) {
        return jsti::fail("No screenshot folder supplied.", error, capacity);
    }
    if (!CreateDirectoryW(folder.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        return jsti::fail(jsti::systemError("Creating the screenshot folder"), error, capacity);
    }
    auto owned = std::make_unique<std::wstring>(std::move(folder));
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window || !PostMessageW(state.window, tourMessage, 0, reinterpret_cast<LPARAM>(owned.get()))) {
        return jsti::fail("The window is not running.", error, capacity);
    }
    owned.release();
    return 0;
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
    // The model, source and mode checks read the Transcription page's controls.
    const int originalPage = state.page;
    showPage(window, transcriptionPage);
    struct Event { int event = 0; std::string id; int model = -1; } observed;
    state.callback = [](int event, const char *id, int model, void *context) {
        auto &observed = *static_cast<Event *>(context);
        observed.event = event; observed.id = id ? id : ""; observed.model = model;
    };
    state.context = &observed;
    std::string failure;
    auto checkBounds = [&]() -> bool {
        SetWindowPos(window, nullptr, 0, 0, minimumWindowWidth(window), minimumWindowHeight(window),
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
        // App profiles has its own page; every page keeps its controls in bounds.
        for (int page = 0; page < pageCount; ++page) {
            showPage(window, page);
            if (!checkBounds()) return false;
            if (page == profilesPage && !IsWindowVisible(GetDlgItem(window, profilesID))) {
                failure = "The Profiles page did not show App profiles."; return false;
            }
            if (page != transcriptionPage && IsWindowVisible(GetDlgItem(window, modelID))) {
                failure = "A page showed another page's controls."; return false;
            }
        }
        showPage(window, transcriptionPage);
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
            jsti_local_models_self_test(window, failure) && jsti_cloud_sync_settings_self_test(window, failure) &&
            jsti_azure_resource_settings_self_test(window, failure);
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
    showPage(window, originalPage);
    if (passed) passed = jsti::hud::selfTest(failure);
    if (passed) passed = jsti::tray::selfTest(failure);
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
