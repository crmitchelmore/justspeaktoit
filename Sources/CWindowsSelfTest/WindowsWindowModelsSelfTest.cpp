// Main window check stages: model modes, refresh and microphones, then the
// model source (Remote/Local) switch.
#include "WindowsWindowSelfTestInternal.hpp"
#include "../CWindowsSupport/WindowsWindowHistoryPage.hpp"
#include "../CWindowsSupport/WindowsWindowGeneralPage.hpp"
#include "../CWindowsSupport/WindowsWindowModelsPage.hpp"

namespace jsti_window {

bool WindowCheck::changeMode(int mode, int expected) {
    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, mode, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(modeID, CBN_SELCHANGE), 0);
    return observed.event == JSTI_EVENT_MODEL_CHANGED && observed.model == expected &&
        selection(window) == expected &&
        (IsWindowEnabled(GetDlgItem(window, importID)) != FALSE) == (mode == 0);
}

// Model modes, recording locks on them, catalogue refresh and microphones.
bool windowModelAndMicrophoneChecks(WindowCheck &check) {
    [[maybe_unused]] HWND window = check.window;
    [[maybe_unused]] WindowCheckEvent &observed = check.observed;
    [[maybe_unused]] std::string &failure = check.failure;
    [[maybe_unused]] const std::function<bool()> &checkBounds = check.checkBounds;
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
    if (observed.model != 0 || !check.changeMode(1, 3)) {
        failure = "Mode change did not restore its preferred global model."; return false;
    }
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
    if (observed.event != JSTI_EVENT_MODEL_CHANGED || observed.model != 1 ||
        !check.changeMode(0, 0) || !check.changeMode(1, 1)) {
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
    if (!check.changeMode(0, 0) || SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 3) {
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
        !check.changeMode(1, 1)) {
        failure = "Refresh changed the selected model identity or mode preference."; return false;
    }
    // Restore the fixture directly; the public API deliberately forbids
    // shrinking identities even after a model has disappeared from discovery.
    modelsState().modelNames = {L"Batch Alpha", L"Live One", L"Batch Beta", L"Live Two"};
    modelsState().modelModes = {0, 1, 0, 1};
    modelsState().modelOrder = {0, 1, 2, 3};
    modelsState().preferredModels[0] = 0;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelsState().knownModelIdentities = {{"batch-a", 0}, {"live-a", 1}, {"batch-b", 0}, {"live-b", 1}};
    }
    if (!populateModels(window)) { failure = "Model fixture restoration failed."; return false; }
    const LRESULT originalMicrophone = SendDlgItemMessageW(window, microphoneID, CB_GETCURSEL, 0, 0);
    if (modelsState().microphones.size() < 2) { failure = "Smoke test requires two synthetic microphone choices."; return false; }
    SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(microphoneID, CBN_SELCHANGE), 0);
    const bool microphoneChanged = observed.event == JSTI_EVENT_MICROPHONE_CHANGED && observed.id == modelsState().microphones[1].id;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
    const bool recordingSnapshot = observed.event == JSTI_EVENT_TOGGLE_RECORDING &&
        observed.id == modelsState().microphones[1].id && observed.model == 1;
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
    const size_t beforeRecordingMicrophoneCount = modelsState().microphones.size();
    jsti_window_update("Microphone refresh status sentinel", "Microphone transcript sentinel", 1);
    applyUpdate(window);
    const JSTIAudioDevice removed[] = {{"usb-b", "USB Beta", 1}};
    if (jsti_window_refresh_microphones(removed, 1, nullptr) != 0) {
        failure = "A microphone removal during capture was rejected."; return false;
    }
    applyUpdate(window);
    if (selectedMicrophone(window) != "usb-a" || modelsState().microphones.size() != beforeRecordingMicrophoneCount ||
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
    if (selectedMicrophone(window) != "usb-a" || modelsState().microphones.size() != 3 ||
        modelsState().microphones.back().name.find(L"unavailable") == std::wstring::npos ||
        modelsState().microphones.front().name.find(L"USB Beta") == std::wstring::npos || observed.event != -500) {
        failure = "An unplugged selection silently changed or lost its unavailable/default label."; return false;
    }
    const JSTIAudioDevice restored[] = {{"usb-b", "USB Beta", 1}, {"usb-a", "USB Alpha renamed", 0}};
    jsti_window_refresh_microphones(restored, 2, nullptr);
    applyUpdate(window);
    if (selectedMicrophone(window) != "usb-a" || modelsState().microphones.size() != 3 ||
        modelsState().microphones.back().name != L"USB Alpha renamed" || observed.event != -500) {
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
    if (!selectedMicrophone(window).empty() || modelsState().microphones.size() != 2 ||
        modelsState().microphones.front().name.find(L"USB Alpha") == std::wstring::npos || observed.event != -500) {
        failure = "Microphone snapshots did not coalesce or the dynamic default changed ID."; return false;
    }
    jsti_window_refresh_microphones(removed, 1, nullptr);
    jsti_window_refresh_microphones(nullptr, 0, "Synthetic enumeration error");
    applyUpdate(window);
    if (modelsState().microphones.size() != 2 || !selectedMicrophone(window).empty() ||
        modelsState().microphones.front().name.find(L"USB Beta") == std::wstring::npos) {
        failure = "An enumeration failure discarded the last complete microphone snapshot."; return false;
    }
    jsti_window_refresh_microphones(nullptr, 0, nullptr);
    applyUpdate(window);
    if (modelsState().microphones.size() != 1 || !selectedMicrophone(window).empty() || observed.event != -500) {
        failure = "No active microphones did not retain the dynamic default without emitting a user change."; return false;
    }
    return true;
}

// The Remote/Local source switch and local model preferences.
bool windowModelSourceChecks(WindowCheck &check) {
    [[maybe_unused]] HWND window = check.window;
    [[maybe_unused]] WindowCheckEvent &observed = check.observed;
    [[maybe_unused]] std::string &failure = check.failure;
    [[maybe_unused]] const std::function<bool()> &checkBounds = check.checkBounds;
    modelsState().modelModes.assign(modelsState().modelNames.size(), 0);
    modelsState().preferredModels[0] = 2;
    modelsState().preferredModels[1] = -1;
    modelsState().activeMode = 0;
    if (!populateModels(window) || !checkBounds() || IsWindowVisible(GetDlgItem(window, modeID)) ||
        IsWindowEnabled(GetDlgItem(window, modeID)) || !IsWindowEnabled(GetDlgItem(window, importID)) ||
        selection(window) != 2 || SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 4) {
        if (failure.empty()) failure = "The all-batch model catalogue lost legacy behaviour.";
        return false;
    }
    // Launch at login shows what the host reports, cannot be changed while
    // the system decides it, and reports one click until the host answers.
    {
        showPage(window, generalPage);
        HWND toggle = GetDlgItem(window, loginItemID);
        auto shows = [&](bool on) { return (GetWindowLongPtrW(toggle, GWLP_USERDATA) != 0) == on; };
        jsti_window_set_login_item(jsti::login::offBySystem, "Turned off in Settings.");
        applyUpdate(window);
        const bool decided = !IsWindowEnabled(toggle) && shows(false) &&
                             loginItemNote() == L"Turned off in Settings." && checkBounds();
        jsti_window_set_login_item(jsti::login::off, "Start minimised.");
        applyUpdate(window);
        observed.event = 0;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(loginItemID, BN_CLICKED), reinterpret_cast<LPARAM>(toggle));
        const bool reported = observed.event == JSTI_EVENT_LOGIN_ITEM && observed.id == "1" && shows(true);
        observed.event = 0;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(loginItemID, BN_CLICKED), reinterpret_cast<LPARAM>(toggle));
        const bool once = observed.event == 0;
        jsti_window_set_login_item(jsti::login::on, "Start minimised.");
        applyUpdate(window);
        const bool settled = IsWindowEnabled(toggle) && shows(true) && loginItemNote().empty();
        showPage(window, transcriptionPage);
        if (!decided || !reported || !once || !settled) {
            if (failure.empty()) failure = "Launch at login did not follow the state the host reported.";
            return false;
        }
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
        modelsState().knownModelIdentities = {{"batch-a", 0}, {"batch-b", 0}, {"batch-c", 0}, {"batch-d", 0}};
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
        !check.changeMode(1, 4)) {
        failure = "Adding the first live mode lost its preference or overlapped the model controls."; return false;
    }
    // Source picker: Remote and Local each keep their own preference, the
    // Local source has no Live mode here, and callbacks keep global indices.
    modelsState().modelNames = {L"Remote Batch", L"Remote Live", L"Local Batch"};
    modelsState().modelModes = {0, 1, 2};
    modelsState().modelOrder = {0, 1, 2};
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelsState().knownModelIdentities = {{"remote-batch", 0}, {"remote-live", 1}, {"local-batch", 2}};
    }
    modelsState().preferredModels[0] = 0;
    modelsState().preferredModels[1] = 1;
    modelsState().preferredModels[2] = 2;
    modelsState().preferredModels[3] = -1;
    modelsState().activeMode = 0;
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
    if (!remoteShown || !localChosen || !sourceLocked || !changeSource(0, 0) || !check.changeMode(1, 1) ||
        !changeSource(1, 2) || !changeSource(0, 0)) {
        failure = "The Source picker lost a source preference, its controls or the global model identity."; return false;
    }
    modelsState().modelNames = {L"Remote Batch", L"Remote Live", L"Local Batch", L"Local Live",
                        L"Imported Local Batch", L"Imported Local Live"};
    modelsState().modelModes = {0, 1, 2, 3, 2, 3};
    modelsState().modelOrder = {0, 1, 2, 3, 4, 5};
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelsState().knownModelIdentities = {{"remote-batch", 0}, {"remote-live", 1}, {"local-batch", 2},
                                     {"local-live", 3}, {"other-batch", 2}, {"other-live", 3}};
    }
    modelsState().preferredModels[3] = 3;
    if (!populateModels(window)) { failure = "Local transfer fixture could not display models."; return false; }
    const int beforeImport = observed.event = -500;
    if (jsti_window_set_local_model_preferences(4, -1) != 0 ||
        jsti_window_set_local_model_preferences(-1, 5) != 0) {
        failure = "Inactive Local choices could not be published."; return false;
    }
    applyUpdate(window);
    if (selection(window) != 0 || observed.event != beforeImport || modelsState().preferredModels[0] != 0 ||
        modelsState().preferredModels[1] != 1 || modelsState().preferredModels[2] != 4 || modelsState().preferredModels[3] != 5 ||
        !changeSource(1, 4) || !check.changeMode(1, 5) || jsti_window_set_local_model_preferences(2, 3) != 0) {
        failure = "Local transfer activated a model or lost an inactive preference."; return false;
    }
    observed.event = -500;
    applyUpdate(window);
    if (selection(window) != 5 || observed.event != -500 || modelsState().preferredModels[3] != 5 ||
        modelsState().preferredModels[2] != 2 ||
        jsti_window_set_local_model_preferences(-2, -1) != -1 ||
        jsti_window_set_local_model_preferences(1, 2) != -1 || !changeSource(0, 1)) {
        failure = "Local transfer replaced the active model or accepted a wrong-mode index."; return false;
    }
    return true;
}

} // namespace jsti_window
