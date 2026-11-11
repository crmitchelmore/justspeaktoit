// The main window's --ui-smoke-test checks. SpeakWindows.exe links this target so CI
// and the bundle verifier still qualify the shipped binary; CWindowsSupport keeps
// product code only.
#include "CWindowsSelfTest.h"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"
#include "../CWindowsSupport/WindowsWindowAboutPage.hpp"
#include "../CWindowsSupport/WindowsWindowBackup.hpp"
#include "../CWindowsSupport/WindowsWindowGeneralPage.hpp"
#include "../CWindowsSupport/WindowsWindowHistoryPage.hpp"
#include "../CWindowsSupport/WindowsWindowModelsPage.hpp"

#include "WindowsWindowSelfTestInternal.hpp"

namespace jsti_window {
void jsti_smoke_stage(const char *stage) {
    std::fputs("jsti-ui-smoke-stage: ", stderr);
    std::fputs(stage, stderr);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}
} // namespace jsti_window

int jsti_window_self_test(char *error, size_t errorCapacity) {
    jsti_smoke_stage("window.self-test.enter");
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("Window checks must run on the UI thread after READY.", error, errorCapacity);
    }
    jsti_smoke_stage("window.escape.begin");
    std::string escapeFailure;
    if (!jsti::globalEscape::selfTest(window, escapeFailure)) {
        return jsti::fail(escapeFailure, error, errorCapacity);
    }
    if (jsti_window_configure_global_escape(0) != -1 || jsti_window_configure_global_escape(2) != -1 ||
        jsti_window_global_escape_is_current(0) != 0) {
        return jsti::fail("Global Escape configuration or invalid-token admission lost its guard.", error, errorCapacity);
    }
    jsti_smoke_stage("window.troubleshooting.begin");
    if (!GetDlgItem(window, troubleshootingID) || !onPage(troubleshootingID, aboutPage) ||
        onPage(troubleshootingID, dashboardPage) || !jsti_troubleshooting_self_test(window))
        return jsti::fail("Troubleshooting entry, independent report state or stale-result checks failed.",
                          error, errorCapacity);
    jsti_smoke_stage("window.troubleshooting.returned");
    const JSTIAboutLink lateAboutLink{"Late", "https://example.com/"};
    if (!onPage(configurationID, correctionsPage) || onPage(configurationID, pronunciationPage))
        return jsti::fail("Correction learning preferences lost their page scope.", error, errorCapacity);
    if (aboutState().aboutLinks.size() != 6 || controlText(GetDlgItem(window, aboutDetailsID)) != aboutState().aboutDetails ||
        aboutState().aboutDetails.find(L"Version:") == std::wstring::npos ||
        jsti_window_configure_about("late", &lateAboutLink, 1) != -1 ||
        jsti_window_configure_about("late", nullptr, 0) != -1)
        return jsti::fail("About metadata, canonical links or invalid input refusal failed.", error, errorCapacity);
    for (size_t i = 0; i < aboutState().aboutLinks.size(); ++i) {
        HWND button = GetDlgItem(window, aboutLinkBaseID + static_cast<int>(i));
        if (!button || controlText(button) != aboutState().aboutLinks[i].title ||
            onPage(aboutLinkBaseID + static_cast<int>(i), dashboardPage) ||
            !onPage(aboutLinkBaseID + static_cast<int>(i), aboutPage))
            return jsti::fail("About link labels or page scope failed.", error, errorCapacity);
    }
    jsti_smoke_stage("window.settings-search.begin");
    if (!settingsSearchSelfTest(window))
        return jsti::fail("Settings search results, keyboard choice, empty state or input refusal failed.",
                          error, errorCapacity);
    jsti_smoke_stage("window.issue-helper.begin");
    { std::string failure;
      if (!jsti_issue_report_self_test(failure)) return jsti::fail(failure, error, errorCapacity); }
    jsti_smoke_stage("window.issue-helper.returned");
    jsti_smoke_stage("window.cleanup-sidebar.begin");
    if (!cleanupPreviewSelfTest(window))
        return jsti::fail("Cleanup preview bounds, coalescing, navigation or retirement failed.", error, errorCapacity);
    jsti_smoke_stage("window.cleanup-preview.returned");
    if (!sidebarStartupSelfTest())
        return jsti::fail("Sidebar pre-window retention, real control application or delivery ownership failed.",
                          error, errorCapacity);
    jsti_smoke_stage("window.sidebar-startup.returned");
    jsti_smoke_stage("window.cleanup-sidebar.returned");
    const JSTISidebarShortcut unknownSidebar[] = {{"unknown-page", 1, "Ctrl+1"}};
    if (jsti_window_set_sidebar_shortcuts(unknownSidebar, 1, 1) != -1)
        return jsti::fail("An unrecognized sidebar destination was accepted.", error, errorCapacity);
    std::string densityFailure;
    if (!densityAndSidebarSelfTest(window, densityFailure)) return jsti::fail(densityFailure, error, errorCapacity);
    char folderError[256] = {};
    if (!GetDlgItem(window, recordingsFolderID) || !GetDlgItem(window, audioCleanupID) ||
        !GetDlgItem(window, backupExportID) || !GetDlgItem(window, backupAudioID) ||
        !GetDlgItem(window, backupProfilesID) ||
        SendDlgItemMessageW(window, backupAudioID, BM_GETCHECK, 0, 0) != BST_CHECKED ||
        SendDlgItemMessageW(window, backupProfilesID, BM_GETCHECK, 0, 0) != BST_UNCHECKED ||
        jsti_window_confirm_audio_cleanup(nullptr, 1, folderError, sizeof(folderError)) == 0 ||
        jsti_shell_open_directory(nullptr, folderError, sizeof(folderError)) == 0) {
        return jsti::fail("Recording folder control or invalid-path refusal failed.", error, errorCapacity);
    }
    const std::vector<MicrophoneRow> originalMicrophones = modelsState().microphones;
    const std::string originalMicrophoneID = modelsState().microphoneSelection;
    const std::vector<HistoryRow> originalHistory = historyView().displayedHistory;
    const std::string originalSelection = selectedHistory(window);
    const std::vector<std::wstring> originalModelNames = modelsState().modelNames;
    const std::vector<int> originalModelModes = modelsState().modelModes;
    const std::vector<int> originalModelOrder = modelsState().modelOrder;
    std::vector<std::pair<std::string, int>> originalModelIdentities;
    std::wstring originalModelStatus;
    bool originalRefreshing;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        originalModelIdentities = modelsState().knownModelIdentities;
        originalModelStatus = modelsState().modelStatus;
        originalRefreshing = modelsState().modelsRefreshing;
    }
    int originalPreferredModels[modeCount];
    std::copy(std::begin(modelsState().preferredModels), std::end(modelsState().preferredModels), originalPreferredModels);
    const int originalMode = modelsState().activeMode;
    const GeneralSettings originalLogin = generalSettings();
    const auto originalCallback = state.callback;
    void *const originalContext = state.context;
    RECT originalBounds{};
    GetWindowRect(window, &originalBounds);
    // The model, source and mode checks read the Transcription page's controls.
    const int originalPage = state.page;
    showPage(window, transcriptionPage);
    WindowCheckEvent observed;
    state.callback = [](int event, const char *id, int model, void *context) {
        auto &observed = *static_cast<WindowCheckEvent *>(context);
        observed.event = event; observed.id = id ? id : ""; observed.model = model; ++observed.calls;
    };
    state.context = &observed;
    const unsigned originalAbsence = exchangeHandsFreeAbsence(0);
    SendMessageW(window, WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0);
    const bool lockEvent = observed.calls == 1 && observed.event == JSTI_EVENT_USER_ABSENT && !observed.id.empty();
    SendMessageW(window, WM_POWERBROADCAST, PBT_APMSUSPEND, 0);
    const bool suspendEvent = observed.calls == 2 && observed.event == JSTI_EVENT_USER_ABSENT && !observed.id.empty();
    SendMessageW(window, WM_WTSSESSION_CHANGE, WTS_SESSION_UNLOCK, 0);
    const bool stayedSuspended = handsFreeAbsenceBits() == 2u && !jsti_window_hands_free_guard_ready();
    SendMessageW(window, WM_POWERBROADCAST, PBT_APMRESUMEAUTOMATIC, 0);
    const bool guardCleared = handsFreeAbsenceBits() == 0;
    exchangeHandsFreeAbsence(originalAbsence);
    const bool absenceEvents = lockEvent && suspendEvent && observed.calls == 2;
    observed = {};
    if (!absenceEvents || !stayedSuspended || !guardCleared) {
        state.callback = originalCallback;
        state.context = originalContext;
        return jsti::fail("Session absence callback or hands-free suspend guard failed.", error, errorCapacity);
    }
    std::string failure;
    auto checkBounds = [&]() -> bool {
        SetWindowPos(window, nullptr, 0, 0, minimumWindowWidth(window), minimumWindowHeight(window),
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        layout(window);
        RECT client{};
        GetClientRect(window, &client);
        for (HWND control : state.controls) {
            // The transcript's accessible-name label is zero-size by design.
            if (!IsWindowVisible(control) || GetDlgCtrlID(control) == transcriptNameID) continue;
            RECT bounds{};
            GetWindowRect(control, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom ||
                bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
                failure = "Native control " + std::to_string(GetDlgCtrlID(control)) +
                    " falls outside the minimum desktop window bounds (" +
                    std::to_string(bounds.left) + "," + std::to_string(bounds.top) + "-" +
                    std::to_string(bounds.right) + "," + std::to_string(bounds.bottom) + ").";
                return false;
            }
        }
        return true;
    };
    auto check = [&]() -> bool {
        emitMigrationBackup(window, "synthetic-backup.zip", migrationBackupOptions(window));
        const bool includesAudio = observed.event == JSTI_EVENT_MIGRATION_EXPORT &&
            observed.id == "synthetic-backup.zip" && observed.model == 1;
        SendDlgItemMessageW(window, backupAudioID, BM_SETCHECK, BST_UNCHECKED, 0);
        emitMigrationBackup(window, "synthetic-history-only.zip", migrationBackupOptions(window));
        const bool historyOnly = observed.event == JSTI_EVENT_MIGRATION_EXPORT &&
            observed.id == "synthetic-history-only.zip" && observed.model == 0;
        SendDlgItemMessageW(window, backupProfilesID, BM_SETCHECK, BST_CHECKED, 0);
        const int capturedProfiles = migrationBackupOptions(window);
        SendDlgItemMessageW(window, backupProfilesID, BM_SETCHECK, BST_UNCHECKED, 0);
        emitMigrationBackup(window, "synthetic-profiles.zip", capturedProfiles);
        const bool profilesOnly = observed.event == JSTI_EVENT_MIGRATION_EXPORT &&
            observed.id == "synthetic-profiles.zip" && observed.model == 2;
        SendDlgItemMessageW(window, backupProfilesID, BM_SETCHECK, BST_CHECKED, 0);
        SendDlgItemMessageW(window, backupAudioID, BM_SETCHECK, BST_CHECKED, 0);
        emitMigrationBackup(window, "synthetic-complete.zip", migrationBackupOptions(window));
        const bool allCategories = observed.event == JSTI_EVENT_MIGRATION_EXPORT &&
            observed.id == "synthetic-complete.zip" && observed.model == 3;
        SendDlgItemMessageW(window, backupProfilesID, BM_SETCHECK, BST_UNCHECKED, 0);
        emitMigrationInspection("synthetic-review.zip");
        const bool inspection = observed.event == JSTI_EVENT_MIGRATION_INSPECT &&
            observed.id == "synthetic-review.zip" && observed.model == 0;
        SendDlgItemMessageW(window, backupAudioID, BM_SETCHECK, BST_CHECKED, 0);
        updateHistoryControls(window, 2);
        const bool backupLocked = !IsWindowEnabled(GetDlgItem(window, backupAudioID)) &&
            !IsWindowEnabled(GetDlgItem(window, backupProfilesID)) &&
            !IsWindowEnabled(GetDlgItem(window, backupExportID)) && !IsWindowEnabled(GetDlgItem(window, backupInspectID));
        updateHistoryControls(window, 0);
        if (!includesAudio || !historyOnly || !profilesOnly || !allCategories || !inspection || !backupLocked ||
            !IsWindowEnabled(GetDlgItem(window, backupProfilesID)) ||
            !IsWindowEnabled(GetDlgItem(window, backupAudioID)) || !IsWindowEnabled(GetDlgItem(window, backupExportID)) ||
            !IsWindowEnabled(GetDlgItem(window, backupInspectID))) {
            failure = "History backup lost its explicit audio choice or idle-only controls."; return false;
        }
        char reportError[256]{};
        std::string report = "Synthetic read-only report.";
        if (jsti_window_show_migration_report(nullptr, reportError, sizeof(reportError)) == 0 ||
            jsti_window_show_migration_report(report.c_str(), reportError, sizeof(reportError)) != 0) {
            failure = "Backup inspection report validation or dispatch failed."; return false;
        }
        report.assign("Changed caller storage");
        bool reportOwned;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            // Taking the report also keeps the automated fixture from opening a modal report.
            reportOwned = takeMigrationReport() == L"Synthetic read-only report.";
        }
        if (!reportOwned) { failure = "Backup inspection report did not own its posted text."; return false; }
        observed = {};
        // Deliberately interleaved global rows prove callbacks do not leak the
        // filtered combo index. These are never sent to the real Swift host.
        modelsState().modelNames = {L"Batch Alpha", L"Live One", L"Batch Beta", L"Live Two"};
        modelsState().modelModes = {0, 1, 0, 1};
        modelsState().modelOrder = {0, 1, 2, 3};
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            modelsState().knownModelIdentities = {{"batch-a", 0}, {"live-a", 1}, {"batch-b", 0}, {"live-b", 1}};
        }
        modelsState().preferredModels[0] = 2;
        modelsState().preferredModels[1] = 3;
        modelsState().preferredModels[2] = modelsState().preferredModels[3] = -1; // No local rows in this fixture.
        modelsState().activeMode = 0;
        if (!populateModels(window) || !checkBounds() || selection(window) != 2 ||
            SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) != 2) {
            if (failure.empty()) failure = "Batch models did not retain their global identity.";
            return false;
        }
        WindowCheck context{window, observed, failure, checkBounds};
        if (!windowModelAndMicrophoneChecks(context) || !windowHistoryChecks(context) ||
            !windowRecordingLockChecks(context) || !windowModelSourceChecks(context)) return false;
        // The Text output modal must block both background recording paths.
        auto setRecording = [](HWND owner, int recording) {
            jsti_window_update(nullptr, nullptr, recording);
            applyUpdate(owner);
        };
        auto recordingBlocked = [](HWND owner, void *context) {
            const int before = static_cast<WindowCheckEvent *>(context)->event;
            SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
            SendMessageW(owner, WM_COMMAND, MAKEWPARAM(recordID, BN_CLICKED), 0);
            return static_cast<WindowCheckEvent *>(context)->event == before;
        };
        auto observe = [](void *context) { return static_cast<WindowCheckEvent *>(context)->event; };
        jsti_smoke_stage("window.later-helpers.begin");
        return jsti_settings_self_test(window, failure) && jsti_profiles_self_test(window, failure) &&
            jsti_history_filters_self_test(window, failure) &&
            jsti_vocabulary_self_test(window, failure) &&
            jsti_text_output_settings_self_test(window, textOutputID, setRecording, recordingBlocked, &observed, failure) &&
            jsti_hotkey_self_test(window, observe, &observed, failure) &&
            jsti_action_shortcuts_self_test(window, failure) && jsti_voice_settings_self_test(window, failure) &&
            jsti_voice_sources_self_test(window, failure) && jsti_voice_credentials_self_test(window, failure) &&
            jsti_local_models_self_test(window, failure) && jsti_api_keys_self_test(window, failure) &&
            jsti_cloud_sync_settings_self_test(window, failure) &&
            jsti_azure_resource_settings_self_test(window, failure) && jsti_configuration_self_test(window, failure)
            && jsti_comparison_self_test(window, failure) && jsti_automation_settings_self_test(window, failure);
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { failure = "Window smoke test could not allocate its temporary state."; }
    jsti_smoke_stage("window.later-check.returned");
    modelsState().microphones = originalMicrophones;
    modelsState().microphoneSelection = originalMicrophoneID;
    populateMicrophones(window);
    SetDlgItemTextW(window, 94, L"&Microphone");
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelsState().microphonesChanged = false;
        modelsState().pendingMicrophones.clear(); modelsState().microphoneError.clear();
    }
    modelsState().modelNames = originalModelNames;
    modelsState().modelModes = originalModelModes;
    modelsState().modelOrder = originalModelOrder;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        modelsState().knownModelIdentities = std::move(originalModelIdentities);
        modelsState().modelStatus = std::move(originalModelStatus);
        modelsState().modelsRefreshing = originalRefreshing;
        modelsState().modelsChanged = true;
        modelsState().pendingModels.clear();
    }
    std::copy(std::begin(originalPreferredModels), std::end(originalPreferredModels), modelsState().preferredModels);
    modelsState().activeMode = originalMode;
    if (!populateModels(window)) { passed = false; failure = "The model catalogue could not be restored after its smoke test."; }
    historyView().suppressSearchEvents = true;
    SetDlgItemTextW(window, searchID, L"");
    historyView().suppressSearchEvents = false;
    applyVariant(window, -1, false, 0);
    applyPlayback(window, playbackIdle, L"", false, 0);
    state.callback = originalCallback;
    state.context = originalContext;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        restoreLoginItem(originalLogin.loginItem, originalLogin.loginItemDetail);
        stageHistoryRows(originalHistory, &originalSelection);
        clearHistoryPlayback();
    }
    applyUpdate(window);
    SetWindowPos(window, nullptr, originalBounds.left, originalBounds.top,
        originalBounds.right - originalBounds.left, originalBounds.bottom - originalBounds.top,
        SWP_NOZORDER | SWP_NOACTIVATE);
    jsti_smoke_stage("window.accessibility.begin");
    for (int page = 0; passed && page < pageCount; ++page) {
        showPage(window, page);
        std::string auditFailure;
        const int checked = jsti::accessibility::audit(window, auditFailure);
        if (checked <= 0) {
            passed = false;
            failure = checked < 0 ? auditFailure + " Page: " + std::to_string(page) + "."
                                  : "Accessibility audit found no focusable controls on page " + std::to_string(page) + ".";
        }
    }
    showPage(window, originalPage);
    jsti_smoke_stage("window.final-helpers.begin");
    if (passed) passed = jsti::hud::selfTest(failure);
    if (passed) passed = jsti::appIcon::selfTest(window, failure);
    if (passed) passed = jsti::tray::selfTest(failure);
    if (passed) passed = shellSelfTest(failure);
    jsti_smoke_stage("window.self-test.returning");
    return passed ? 0 : jsti::fail(failure, error, errorCapacity);
}
