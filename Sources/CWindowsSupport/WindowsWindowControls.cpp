// Window controls: creation, the dashboard transcript, cleanup preview and the update pump.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {

void retireCleanupPreview() {
    std::lock_guard<std::mutex> lock(cleanupPreview.mutex);
    ++cleanupPreview.ticket;
    cleanupPreview.active = false;
    cleanupPreview.changed = false;
    cleanupPreview.text.clear();
}

void applyCleanupPreview(HWND window) {
    std::lock_guard<std::mutex> lock(cleanupPreview.mutex);
    if (!cleanupPreview.changed) return;
    cleanupPreview.changed = false;
    if (!cleanupPreview.active || state.displayedRecording != 2 ||
        (state.page != dashboardPage && state.page != historyPage)) return;
    SetDlgItemTextW(window, transcriptID, cleanupPreview.text.c_str());
    SetDlgItemTextW(window, statusID, L"Streaming cleanup preview. The original is saved in History.");
    state.history.historyPresentationReady = false;
    EnableWindow(GetDlgItem(window, copyID), FALSE);
}

void emit(HWND window, int event, const char *text) {
    if (state.callback) state.callback(event, text, selection(window), state.context);
}

// The CLI and MCP setup dialog shows and changes the same automation state as
// General's switch: the host's last report, and the same toggle event.
bool automationShownEnabled() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.general.automationEnabled;
}

void requestAutomationToggle(HWND window) {
    emit(window, JSTI_EVENT_AUTOMATION_TOGGLED, automationShownEnabled() ? "0" : "1");
}

std::string selectedMicrophone(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, microphoneID, CB_GETCURSEL, 0, 0);
    if (index == CB_ERR || static_cast<size_t>(index) >= state.models.microphones.size()) return {};
    return state.models.microphones[static_cast<size_t>(index)].id;
}

void emitRecording(HWND window) {
    // Registered hotkeys still reach a disabled owner through a modal loop.
    // Child controls keep their enabled flags, so check the owner as well.
    if (!IsWindowEnabled(window)) return;
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    if (recording == 2) { retireCleanupPreview(); emit(window, JSTI_EVENT_CANCEL_TRANSCRIPTION); return; }
    const std::string device = selectedMicrophone(window);
    emit(window, JSTI_EVENT_TOGGLE_RECORDING, device.c_str());
}

void showFailure(HWND window, const std::string &message) {
    emit(window, JSTI_EVENT_ERROR, message.c_str());
    std::wstring wide;
    if (jsti::wide(message.c_str(), wide)) SetDlgItemTextW(window, statusID, wide.c_str());
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
    // The search label precedes its box, so the box's accessible name is
    // "Search settings"; results are hidden until a search opens.
    state.wanted[settingsResultsID] = false;
    state.wanted[settingsNoMatchID] = false;
    bool okay = add(L"STATIC", L"Search settings", 0, settingsSearchLabelID) &&
        add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, settingsSearchID) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_VSCROLL |
            WS_TABSTOP, settingsResultsID) &&
        add(L"STATIC", L"No settings match", 0, settingsNoMatchID);
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
        add(L"BUTTON", L"Fil&ters...", BS_PUSHBUTTON | WS_TABSTOP, historyFiltersID) &&
        add(L"BUTTON", L"Create issue with details...", BS_PUSHBUTTON | BS_MULTILINE | WS_TABSTOP, issueReportID) &&
        add(L"BUTTON", L"Delete...", BS_PUSHBUTTON | WS_TABSTOP, historyDeleteID) &&
        add(L"BUTTON", L"Clear history...", BS_PUSHBUTTON | WS_TABSTOP, historyClearID) &&
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
        add(L"BUTTON", L"Co&rrections...", BS_PUSHBUTTON | WS_TABSTOP, historyCorrectionsID) &&
        // The label carries the mnemonic and precedes Play/Pause, so Alt+B
        // and assistive technology reach the playback controls.
        add(L"STATIC", L"Play&back", 0, playbackLabelID) &&
        add(L"STATIC", playbackIdleText, 0, playbackTimeID) &&
        add(L"BUTTON", L"Play", BS_PUSHBUTTON | WS_TABSTOP, playPauseID) &&
        add(L"BUTTON", L"Stop", BS_PUSHBUTTON | WS_TABSTOP, stopPlaybackID) &&
        add(L"BUTTON", L"Choose &voice…", BS_PUSHBUTTON | WS_TABSTOP, voiceSettingsID) &&
        add(L"BUTTON", L"&Text and export...", BS_PUSHBUTTON | WS_TABSTOP, voiceSourcesID) &&
        add(L"BUTTON", L"Provider &key...", BS_PUSHBUTTON | WS_TABSTOP, voiceCredentialID) &&
        add(L"BUTTON", L"Edit app &profiles…", BS_PUSHBUTTON | WS_TABSTOP, profilesID) &&
        add(L"BUTTON", L"Edit &corrections...", BS_PUSHBUTTON | WS_TABSTOP, correctionsID) &&
        add(L"BUTTON", L"Edit &pronunciations...", BS_PUSHBUTTON | WS_TABSTOP, pronunciationID) &&
        add(L"BUTTON", L"Compare &Models...", BS_PUSHBUTTON | WS_TABSTOP, comparisonID) &&
        add(L"STATIC", L"&Source", 0, sourceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, sourceID) &&
        add(L"STATIC", L"&Mode", 0, 95) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, modeID) &&
        add(L"STATIC", L"", 0, shortcutValueID) &&
        add(L"BUTTON", L"Change &keyboard shortcut…", BS_PUSHBUTTON | WS_TABSTOP, shortcutID) &&
        add(L"BUTTON", L"&Action shortcuts…", BS_PUSHBUTTON | WS_TABSTOP, actionShortcutsID) &&
        add(L"STATIC", L"&Transcription model", 0, 90) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"BUTTON", L"Configure &post-processing…", BS_PUSHBUTTON | WS_TABSTOP, processingID) &&
        add(L"STATIC", L"OpenRouter discovery not loaded.", 0, modelStatusID) &&
        add(L"BUTTON", L"Refresh &models", BS_PUSHBUTTON | WS_TABSTOP, modelRefreshID) &&
        add(L"BUTTON", L"Local mo&dels…", BS_PUSHBUTTON | WS_TABSTOP, localModelsID) &&
        add(L"STATIC", L"&API key (Windows Credential Manager)", 0, 91) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"BUTTON", L"All API &keys…", BS_PUSHBUTTON | WS_TABSTOP, apiKeysID) &&
        add(L"BUTTON", L"A&zure Speech resource…", BS_PUSHBUTTON | WS_TABSTOP, azureID) &&
        add(L"STATIC", L"&Microphone", 0, 94) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, microphoneID) &&
        add(L"BUTTON", L"Text o&utput…", BS_PUSHBUTTON | WS_TABSTOP, textOutputID) &&
        add(L"BUTTON", L"Dictation &preferences...", BS_PUSHBUTTON | WS_TABSTOP, configurationID) &&
        add(L"STATIC", L"&Theme", 0, appearanceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, appearanceID) &&
        add(L"BUTTON", L"Launch at &login", BS_PUSHBUTTON | WS_TABSTOP, loginItemID) &&
        add(L"BUTTON", L"Allow &automation (speak command and MCP)", BS_PUSHBUTTON | WS_TABSTOP, automationID) &&
        add(L"BUTTON", L"CLI and MCP s&etup…", BS_PUSHBUTTON | WS_TABSTOP, automationSettingsID) &&
        add(L"STATIC", L"Recording storage", 0, recordingsFolderLabelID) &&
        add(L"BUTTON", L"Open &folder", BS_PUSHBUTTON | WS_TABSTOP, recordingsFolderID) &&
        add(L"BUTTON", L"Delete all a&udio...", BS_PUSHBUTTON | WS_TABSTOP, audioCleanupID) &&
        add(L"BUTTON", L"&Saved audio", BS_AUTOCHECKBOX | WS_TABSTOP, backupAudioID) &&
        add(L"BUTTON", L"App &profiles", BS_AUTOCHECKBOX | WS_TABSTOP, backupProfilesID) &&
        add(L"BUTTON", L"Save &ZIP backup...", BS_PUSHBUTTON | WS_TABSTOP, backupExportID) &&
        add(L"BUTTON", L"&Inspect backup...", BS_PUSHBUTTON | WS_TABSTOP, backupInspectID) &&
        add(L"BUTTON", L"Restore backup...", BS_PUSHBUTTON | WS_TABSTOP, backupRestoreID) &&
        add(L"BUTTON", L"i&Cloud sync settings…", BS_PUSHBUTTON | WS_TABSTOP, cloudSyncID) &&
        add(L"STATIC", state.about.aboutDetails.c_str(), 0, aboutDetailsID) &&
        add(L"BUTTON", L"Ru&n setup again…", BS_PUSHBUTTON | WS_TABSTOP, setupGuideID) &&
        add(L"BUTTON", L"&Windows permissions…", BS_PUSHBUTTON | WS_TABSTOP, permissionsID) &&
        add(L"BUTTON", L"&Troubleshooting…", BS_PUSHBUTTON | WS_TABSTOP, troubleshootingID) &&
        add(L"STATIC", jsti_hotkey_label().c_str(), 0, transcriptLabelID) &&
        add(L"STATIC", L"Transcript", 0, transcriptNameID) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, transcriptID) &&
        add(L"BUTTON", L"&Copy transcript", BS_PUSHBUTTON | WS_TABSTOP, copyID);
    for (size_t i = 0; i < state.about.aboutLinks.size() && okay; ++i)
        okay = add(L"BUTTON", state.about.aboutLinks[i].title.c_str(), BS_PUSHBUTTON | WS_TABSTOP,
            aboutLinkBaseID + static_cast<int>(i));
    SendDlgItemMessageW(window, backupAudioID, BM_SETCHECK, BST_CHECKED, 0);
    for (int identifier : {chipSessionsID, chipTimeID, chipSpendID, insightSessionsID, insightTimeID, insightAverageID,
                           insightSpendID, historySessionsID, historyErrorsID, historyAverageID, historySpendID,
                           setupMicrophoneID, setupModelID, setupShortcutID, setupOutputID}) {
        okay = okay && add(L"STATIC", L"—", 0, identifier);
    }
    okay = okay && add(L"STATIC", L"Ready. Choose a model and save its API key to begin.", 0, statusID);
    LRESULT selectedDevice = 0;
    for (size_t i = 0; i < state.models.microphones.size(); ++i) {
        const auto &device = state.models.microphones[i];
        const LRESULT added = SendDlgItemMessageW(window, microphoneID, CB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(device.name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
        if (device.id == state.models.microphoneSelection) selectedDevice = static_cast<LRESULT>(i);
    }
    SendDlgItemMessageW(window, microphoneID, CB_SETCURSEL, selectedDevice, 0);
    SendDlgItemMessageW(window, keyID, EM_LIMITTEXT, 2048, 0);
    SendDlgItemMessageW(window, searchID, EM_LIMITTEXT, 512, 0);
    SendDlgItemMessageW(window, searchID, EM_SETCUEBANNER, TRUE,
                        reinterpret_cast<LPARAM>(L"Search transcripts, models and profiles"));
    SendDlgItemMessageW(window, settingsSearchID, EM_LIMITTEXT, 256, 0);
    SendDlgItemMessageW(window, settingsSearchID, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"Search settings"));
    SendDlgItemMessageW(window, transcriptID, EM_LIMITTEXT, 4 * 1024 * 1024, 0);
    SetWindowPos(GetDlgItem(window, transcriptNameID), nullptr, 0, 0, 0, 0, SWP_NOZORDER | SWP_NOACTIVATE);
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
    EnableWindow(GetDlgItem(window, actionShortcutsID), jsti_action_shortcuts_available());
    std::wstring modelStatus;
    bool refreshing;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelStatus = state.models.modelStatus;
        refreshing = state.models.modelsRefreshing;
    }
    state.models.remoteModelStatus = modelStatus;
    updateSourceControls(window);
    EnableWindow(GetDlgItem(window, modelRefreshID), !refreshing);
    applyTheme(window);
    refreshSetup(window);
    layout(window);
    return okay;
}

// Settings that were menu commands follow their dialogs' idle rules; the
// automation switch shows the state the host reported.
void updateSettingsButtons(HWND window, int recording) {
    EnableWindow(GetDlgItem(window, configurationID), recording == 0);
    EnableWindow(GetDlgItem(window, voiceSettingsID), recording == 0 && jsti_voice_output_available());
    EnableWindow(GetDlgItem(window, localModelsID), recording == 0 && jsti_local_models_available());
    EnableWindow(GetDlgItem(window, cloudSyncID), recording == 0 && jsti_cloud_sync_available());
    EnableWindow(GetDlgItem(window, azureID), recording == 0 && jsti_azure_resource_available());
    EnableWindow(GetDlgItem(window, automationSettingsID), recording == 0);
    EnableWindow(GetDlgItem(window, apiKeysID), recording == 0 && jsti_api_keys_available());
    bool automation, loginPending;
    int login;
    std::wstring loginDetail;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        automation = state.general.automationEnabled;
        login = state.general.loginItem;
        loginPending = state.general.loginItemPending;
        loginDetail = state.general.loginItemDetail;
    }
    auto show = [&](int identifier, bool on) {
        HWND toggle = GetDlgItem(window, identifier);
        if ((GetWindowLongPtrW(toggle, GWLP_USERDATA) != 0) == on) return;
        SetWindowLongPtrW(toggle, GWLP_USERDATA, on ? 1 : 0);
        InvalidateRect(toggle, nullptr, FALSE);
    };
    show(automationID, automation);
    // A pending click keeps showing the choice until the host reports.
    if (!loginPending) show(loginItemID, login == jsti::login::on || login == jsti::login::onBySystem);
    EnableWindow(GetDlgItem(window, loginItemID), login == jsti::login::off || login == jsti::login::on);
    const bool decided = login == jsti::login::offBySystem || login == jsti::login::onBySystem ||
                         login == jsti::login::unavailable;
    std::wstring note = decided ? loginDetail : std::wstring();
    if (note != state.general.loginItemNote) {
        state.general.loginItemNote.swap(note);
        if (state.page == generalPage) layout(window);
    }
}

// History totals from jsti_window_set_insights, shown only when they change.
void applyInsights(HWND window) {
    std::wstring values[2][5];
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.dashboard.insightsChanged) return;
        state.dashboard.insightsChanged = false;
        for (int group = 0; group < 2; ++group) for (int index = 0; index < 5; ++index) values[group][index] = state.dashboard.insights[group][index];
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
    std::wstring status, transcript, migrationReport;
    bool microphonesChanged;
    std::vector<MicrophoneRow> microphones;
    std::wstring microphoneError;
    bool statusChanged, transcriptChanged, historyChanged, variantChanged, variantSwitchable;
    bool modelsChanged, modelsRefreshing, localModelPreferencesChanged;
    int localModelPreferences[2];
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
        status.swap(state.dashboard.status); transcript.swap(state.dashboard.transcript);
        migrationReport.swap(state.history.migrationReport);
        presentationChanged = state.history.presentationChanged;
        if (presentationChanged) presentation = std::move(state.history.pendingPresentation);
        state.history.presentationChanged = false;
        playbackChanged = state.history.playbackChanged;
        playbackRecord = state.history.pendingPlaybackRecord;
        playback = state.history.pendingPlaybackState;
        playbackText = state.history.pendingPlaybackText;
        state.history.playbackChanged = false;
        modelsChanged = state.models.modelsChanged;
        modelsRefreshing = state.models.modelsRefreshing;
        if (modelsChanged) { models = std::move(state.models.pendingModels); modelStatus = state.models.modelStatus; }
        state.models.modelsChanged = false;
        localModelPreferencesChanged = state.models.localModelPreferencesChanged;
        std::copy(std::begin(state.models.pendingLocalModelPreferences), std::end(state.models.pendingLocalModelPreferences),
                  localModelPreferences);
        std::fill(std::begin(state.models.pendingLocalModelPreferences), std::end(state.models.pendingLocalModelPreferences), -1);
        state.models.localModelPreferencesChanged = false;
        statusChanged = state.dashboard.statusChanged; transcriptChanged = state.dashboard.transcriptChanged;
        state.dashboard.statusChanged = false; state.dashboard.transcriptChanged = false;
        historyChanged = state.history.historyChanged;
        if (historyChanged) {
            history = std::move(state.history.pendingHistory);
            explicitHistorySelection = state.history.historySelectionProvided &&
                state.history.pendingHistoryRevision == state.history.historyInteractionRevision;
            historySelection = explicitHistorySelection ? state.history.pendingHistorySelection : state.history.selectedHistoryID;
            state.history.historyChanged = false;
        }
        variantChanged = state.history.variantChanged;
        variantRecord = state.history.pendingVariantRecord;
        variant = state.history.pendingVariant;
        variantSwitchable = state.history.pendingVariantSwitchable;
        state.history.variantChanged = false;
        state.posted = false;
        recording = state.recording;
        microphonesChanged = state.models.microphonesChanged && recording == 0;
        if (microphonesChanged) {
            microphones = std::move(state.models.pendingMicrophones);
            microphoneError = state.models.microphoneError;
            state.models.microphonesChanged = false;
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
        state.models.remoteModelStatus = modelStatus;
        EnableWindow(GetDlgItem(window, modelRefreshID), !modelsRefreshing);
    }
    if (localModelPreferencesChanged) {
        for (int i = 0; i < 2; ++i) {
            const int index = localModelPreferences[i], mode = i + 2;
            if (index < 0 || state.models.activeMode == mode) continue;
            if (static_cast<size_t>(index) < state.models.modelModes.size() && state.models.modelModes[index] == mode)
                state.models.preferredModels[mode] = index;
            else {
                status = L"Saved Local model choice is unavailable. Reopen the app before switching modes.";
                statusChanged = true;
            }
        }
    }
    updateSourceControls(window);
    if (statusChanged) SetDlgItemTextW(window, statusID, status.c_str());
    std::string escapeFailure;
    if (!jsti::globalEscape::reconcile(window, state.globalEscapeEnabled, showFailure, escapeFailure) &&
        !escapeFailure.empty()) showFailure(window, escapeFailure);
    applyInsights(window);

    SetDlgItemTextW(window, recordID, recording == 1 ? L"&Stop recording" : (recording == 2 ? L"&Cancel" : L"&Record"));
    EnableWindow(GetDlgItem(window, recordID), TRUE);
    if (state.displayedRecording != recording) {
        state.displayedRecording = recording;
        InvalidateRect(GetDlgItem(window, recordID), nullptr, FALSE);
        SetTimer(window, announceTimerID, 150, nullptr);
        jsti::tray::setState(recording, state.traySummary);
    }
    for (int id : {keyID, saveID, microphoneID, profilesID}) EnableWindow(GetDlgItem(window, id), recording == 0);
    updateModelAvailability(window, recording);
    EnableWindow(GetDlgItem(window, processingID), recording == 0 && jsti_postprocessing_available());
    EnableWindow(GetDlgItem(window, textOutputID), recording == 0 && jsti_text_output_available());
    EnableWindow(GetDlgItem(window, shortcutID), recording == 0 && jsti_hotkey_available());
    EnableWindow(GetDlgItem(window, actionShortcutsID), recording == 0 && jsti_action_shortcuts_available());
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
        state.history.displayedHistory = std::move(history);
        state.history.historyMoreRequested = false;
        LRESULT selectedIndex = LB_ERR;
        bool failed = false;
        for (size_t i = 0; i < state.history.displayedHistory.size(); ++i) {
            const auto &entry = state.history.displayedHistory[i];
            const LRESULT added = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(entry.title.c_str()));
            if (added == LB_ERR || added == LB_ERRSPACE) { failed = true; break; }
            if (entry.id == historySelection) selectedIndex = static_cast<LRESULT>(i);
        }
        if (failed) {
            SendMessageW(list, LB_RESETCONTENT, 0, 0);
            state.history.displayedHistory.clear();
            selectedIndex = LB_ERR;
        }
        SendMessageW(list, LB_SETCURSEL, static_cast<WPARAM>(selectedIndex), 0);
        if (oldTop > 0 && static_cast<size_t>(oldTop) < state.history.displayedHistory.size()) {
            SendMessageW(list, LB_SETTOPINDEX, static_cast<WPARAM>(oldTop), 0);
        }
        SendMessageW(list, WM_SETREDRAW, TRUE, 0);
        InvalidateRect(list, nullptr, TRUE);
        const std::string nowSelected = selectedHistory(window);
        bool selectionChanged;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            selectionChanged = nowSelected != state.history.selectedHistoryID;
            state.history.selectedHistoryID = nowSelected;
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
        (state.history.requestedVariant < 0 || state.history.requestedVariant == variant)) {
        applyVariant(window, variant, variantSwitchable, recording);
    }
    // Untagged text belongs to active capture or a result outside the History
    // selection. Saved-record text uses the atomic, identity-checked path below.
    if (transcriptChanged && (recording != 0 || selectedHistory(window).empty())) {
        SetDlgItemTextW(window, transcriptID, transcript.c_str());
        state.history.historyPresentationReady = selectedHistory(window).empty();
    }
    if (presentationChanged && presentation.record == selectedHistory(window) &&
        (state.history.requestedVariant < 0 || state.history.requestedVariant == presentation.variant)) {
        SetDlgItemTextW(window, transcriptID, presentation.transcript.c_str());
        SetDlgItemTextW(window, statusID, presentation.status.c_str());
        state.history.historyPresentationReady = presentation.variant >= 0;
        state.history.requestedVariant = presentation.variant;
        applyVariant(window, presentation.variant, presentation.switchable, recording);
    }
    if (playbackChanged) {
        const std::string nowSelected = selectedHistory(window);
        if (playbackRecord.empty()) applyPlayback(window, playbackIdle, L"", !nowSelected.empty(), recording);
        else if (playbackRecord == nowSelected) applyPlayback(window, playback, playbackText, true, recording);
    }
    updateHistoryControls(window, recording);
    refreshSetup(window);
    applyCleanupPreview(window);
    if (!migrationReport.empty() && IsWindow(window)) {
        MessageBoxW(window, migrationReport.c_str(), L"Backup inspection (read only)", MB_OK | MB_ICONINFORMATION);
    }
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
} // namespace jsti_window

uint64_t jsti_window_begin_cleanup_preview(void) {
    std::lock_guard<std::mutex> lock(cleanupPreview.mutex);
    if (++cleanupPreview.ticket == 0) ++cleanupPreview.ticket;
    cleanupPreview.active = true;
    cleanupPreview.changed = false;
    cleanupPreview.text.clear();
    return cleanupPreview.ticket;
}

void jsti_window_end_cleanup_preview(uint64_t ticket) {
    std::lock_guard<std::mutex> lock(cleanupPreview.mutex);
    if (ticket != cleanupPreview.ticket) return;
    ++cleanupPreview.ticket;
    cleanupPreview.active = false;
    cleanupPreview.changed = false;
    cleanupPreview.text.clear();
}

int jsti_window_cleanup_preview(const char *text, uint64_t ticket) {
    if (!text || std::strlen(text) > 65536) return -1;
    std::wstring wide;
    if (!jsti::wide(text, wide)) return -1;
    std::lock_guard<std::mutex> previewLock(cleanupPreview.mutex);
    if (!cleanupPreview.active || ticket != cleanupPreview.ticket) return 1;
    cleanupPreview.text = std::move(wide);
    cleanupPreview.changed = true;
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window) return -1;
    if (!state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return state.posted ? 0 : -1;
}
