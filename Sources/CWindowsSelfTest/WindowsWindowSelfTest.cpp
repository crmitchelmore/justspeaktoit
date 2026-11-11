// The main window's --ui-smoke-test checks. SpeakWindows.exe links this target so CI
// and the bundle verifier still qualify the shipped binary; CWindowsSupport keeps
// product code only.
#include "CWindowsSelfTest.h"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"

namespace jsti_window {

struct SidebarStartupFixture {
    SidebarDelivery delivery;
    SidebarBindings applied;
    HWND window = nullptr;
};

LRESULT CALLBACK sidebarStartupFixtureProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lparam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto *fixture = reinterpret_cast<SidebarStartupFixture *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (fixture && message == WM_CREATE) {
        for (int page = 0; page < pageCount; ++page) {
            if (!CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 160, 36,
                window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(navBaseID + page)),
                GetModuleHandleW(nullptr), nullptr)) return -1;
        }
        fixture->window = window;
        auto initial = fixture->delivery.claimInitial();
        if (initial) fixture->applied = std::move(*initial);
        applySidebarBindings(window, fixture->applied);
        return 0;
    }
    if (fixture && message == sidebarMessage) {
        auto update = fixture->delivery.claim(wparam);
        if (update) {
            fixture->applied = std::move(*update);
            applySidebarBindings(window, fixture->applied);
        }
        return 0;
    }
    if (fixture && message == WM_DESTROY) {
        fixture->window = nullptr;
        fixture->delivery.retire();
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

bool sidebarStartupSelfTest() {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = sidebarStartupFixtureProcedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItSidebarStartupFixture";
    if (!RegisterClassW(&type)) return false;
    const JSTISidebarShortcut bindings[] = {{"dashboard", 1, "Ctrl+1"}, {"history", 2, "Ctrl+2"}};
    SidebarStartupFixture fixture;
    UINT_PTR lastRetired = 0;
    bool okay = true;
    for (int hints : {0, 1}) {
        okay = configureSidebarShortcuts(fixture.delivery, nullptr, bindings, 2, hints) == 0 && okay;
        const auto *retained = fixture.delivery.initial.get();
        okay = okay && retained && retained->showHints == (hints != 0);
        const JSTISidebarShortcut invalid[] = {
            {"unknown-page", 3, "Ctrl+3"}, {"dashboard", 3, "Ctrl+Shift+3"},
            {"dashboard", 10, "Ctrl+10"}, {"dashboard", 3, "\xFF"}, {nullptr, 3, "Ctrl+3"}
        };
        for (const auto &binding : invalid)
            okay = configureSidebarShortcuts(fixture.delivery, nullptr, &binding, 1, hints) == -1 &&
                fixture.delivery.initial.get() == retained && okay;
        const JSTISidebarShortcut repeatedID[] = {{"dashboard", 1, "Ctrl+1"}, {"dashboard", 2, "Ctrl+2"}};
        const JSTISidebarShortcut repeatedDigit[] = {{"dashboard", 1, "Ctrl+1"}, {"history", 1, "Ctrl+1"}};
        okay = configureSidebarShortcuts(fixture.delivery, nullptr, repeatedID, 2, hints) == -1 &&
            configureSidebarShortcuts(fixture.delivery, nullptr, repeatedDigit, 2, hints) == -1 &&
            configureSidebarShortcuts(fixture.delivery, nullptr, bindings, 2, 2) == -1 &&
            fixture.delivery.initial.get() == retained && okay;
        HWND window = CreateWindowExW(0, type.lpszClassName, L"Sidebar startup fixture", WS_POPUP,
            0, 0, 1, 1, nullptr, nullptr, instance, &fixture);
        if (!window) { okay = false; break; }
        const bool reserved = jsti_hotkey_reserves_sidebar_digit(1);
        auto label = [&](bool shown) { return shown && !reserved ? L"Dashboard (Ctrl+1)" : L"Dashboard"; };
        okay = okay && !fixture.delivery.initial && fixture.applied.digits[dashboardPage] == 1 &&
            fixture.applied.digits[historyPage] == 2 && fixture.applied.showHints == (hints != 0) &&
            controlText(GetDlgItem(window, navBaseID)) == label(hints != 0);
        okay = configureSidebarShortcuts(fixture.delivery, window, bindings, 2, !hints) == 0 &&
            fixture.delivery.posted.size() == 1 &&
            fixture.delivery.sequence > lastRetired && !fixture.delivery.claim(lastRetired) &&
            controlText(GetDlgItem(window, navBaseID)) == label(hints != 0) && okay;
        MSG message{};
        while (!fixture.delivery.posted.empty() &&
               PeekMessageW(&message, window, sidebarMessage, sidebarMessage, PM_REMOVE)) {
            if (message.message == WM_QUIT) { PostQuitMessage(static_cast<int>(message.wParam)); okay = false; break; }
            DispatchMessageW(&message);
        }
        okay = okay && fixture.delivery.posted.empty() && fixture.applied.showHints == (hints == 0) &&
            controlText(GetDlgItem(window, navBaseID)) == label(hints == 0);
        okay = configureSidebarShortcuts(fixture.delivery, window, bindings, 2, hints) == 0 &&
            fixture.delivery.posted.size() == 1 && okay;
        const UINT_PTR retired = fixture.delivery.sequence;
        DestroyWindow(window);
        okay = okay && !fixture.window && fixture.delivery.posted.empty() && !fixture.delivery.claim(retired);
        lastRetired = retired;
        const HWND invalidWindow = reinterpret_cast<HWND>(static_cast<INT_PTR>(-2));
        okay = configureSidebarShortcuts(fixture.delivery, invalidWindow, bindings, 2, hints) == -1 &&
            fixture.delivery.posted.empty() && okay;
    }
    UnregisterClassW(type.lpszClassName, instance);
    return okay;
}
} // namespace jsti_window

// Validation and retention of App visibility, and the owner change that takes
// a window off the taskbar, on a private hidden fixture.
static bool shellSelfTest(std::string &failure) {
    ShellDelivery startup;
    bool okay = configureShell(startup, nullptr, 3, 0) == -1 && configureShell(startup, nullptr, -1, 0) == -1 &&
        configureShell(startup, nullptr, shellTrayOnly, 2) == -1 && !startup.initial;
    okay = configureShell(startup, nullptr, shellTrayOnly, 1) == 0 && okay;
    auto admitted = startup.claimInitial();
    okay = okay && admitted && admitted->visibility == shellTrayOnly && admitted->compact && !startup.initial;
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    HWND owner = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
        instance, nullptr);
    HWND fixture = CreateWindowExW(0, L"STATIC", L"", WS_OVERLAPPEDWINDOW, 0, 0, 10, 10, nullptr, nullptr,
        instance, nullptr);
    okay = okay && owner && fixture && GetWindow(fixture, GW_OWNER) == nullptr;
    if (owner && fixture) {
        SetWindowLongPtrW(fixture, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner));
        okay = okay && GetWindow(fixture, GW_OWNER) == owner;
        SetWindowLongPtrW(fixture, GWLP_HWNDPARENT, 0);
        okay = okay && GetWindow(fixture, GW_OWNER) == nullptr;
    }
    if (fixture) DestroyWindow(fixture);
    if (owner) DestroyWindow(owner);
    if (!okay) failure = "App visibility validation, retention or taskbar ownership failed.";
    return okay;
}

static bool cleanupPreviewSelfTest(HWND window) {
    const int page = state.page;
    const bool ready = state.historyPresentationReady;
    std::wstring originalText(static_cast<size_t>(GetWindowTextLengthW(GetDlgItem(window, transcriptID))) + 1, 0);
    std::wstring originalStatus(static_cast<size_t>(GetWindowTextLengthW(GetDlgItem(window, statusID))) + 1, 0);
    GetDlgItemTextW(window, transcriptID, &originalText[0], static_cast<int>(originalText.size()));
    GetDlgItemTextW(window, statusID, &originalStatus[0], static_cast<int>(originalStatus.size()));
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    showPage(window, dashboardPage);
    jsti_window_update(nullptr, nullptr, 2);
    applyUpdate(window);
    const uint64_t first = jsti_window_begin_cleanup_preview();
    bool okay = jsti_window_cleanup_preview("first", first) == 0 &&
        jsti_window_cleanup_preview("latest", first) == 0;
    applyUpdate(window);
    wchar_t actual[128] = {};
    GetDlgItemTextW(window, transcriptID, actual, 128);
    okay = okay && wcscmp(actual, L"latest") == 0 && !IsWindowEnabled(GetDlgItem(window, copyID));
    showPage(window, generalPage);
    showPage(window, dashboardPage);
    okay = okay && jsti_window_cleanup_preview("away/back stale", first) == 1;
    const uint64_t second = jsti_window_begin_cleanup_preview();
    okay = okay && second != first && jsti_window_cleanup_preview("replacement", second) == 0;
    jsti_window_end_cleanup_preview(first);
    applyUpdate(window);
    GetDlgItemTextW(window, transcriptID, actual, 128);
    okay = okay && wcscmp(actual, L"replacement") == 0;
    okay = okay && jsti_window_cleanup_preview(std::string(65536, 'x').c_str(), second) == 0;
    jsti_window_end_cleanup_preview(second);
    applyUpdate(window);
    GetDlgItemTextW(window, transcriptID, actual, 128);
    okay = okay && wcscmp(actual, L"replacement") == 0;
    okay = okay && jsti_window_cleanup_preview("retired", second) == 1 &&
        jsti_window_cleanup_preview(std::string(65537, 'x').c_str(), second) == -1 &&
        jsti_window_cleanup_preview("\xff", second) == -1;
    jsti_window_update(nullptr, nullptr, recording);
    applyUpdate(window);
    state.historyPresentationReady = ready;
    showPage(window, page);
    SetDlgItemTextW(window, transcriptID, originalText.c_str());
    SetDlgItemTextW(window, statusID, originalStatus.c_str());
    updateHistoryControls(window, recording);
    return okay;
}

static void jsti_smoke_stage(const char *stage) {
    std::fputs("jsti-ui-smoke-stage: ", stderr);
    std::fputs(stage, stderr);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

// Results replace the list and read as "<title>, <detail>"; Enter reports the
// chosen row and closes the search; an empty set says "No settings match";
// invalid input and an unknown preference are refused.
static bool settingsSearchSelfTest(HWND window) {
    struct Observed { int event = 0, row = -1, calls = 0; std::string text; } observed;
    const auto originalCallback = state.callback;
    void *const originalContext = state.context;
    HWND originalFocus = GetFocus();
    state.callback = [](int event, const char *text, int row, void *context) {
        auto &seen = *static_cast<Observed *>(context);
        seen.event = event; seen.text = text ? text : ""; seen.row = row; ++seen.calls;
    };
    state.context = &observed;
    auto visible = [&](int identifier) {
        return (GetWindowLongW(GetDlgItem(window, identifier), GWL_STYLE) & WS_VISIBLE) != 0;
    };
    const std::vector<JSTISettingsSearchResult> tooMany(maximumSettingsResults + 1,
        JSTISettingsSearchResult{"Title", "Detail", "settingsSearchResult.title"});
    const JSTISettingsSearchResult missing{"Title", nullptr, "settingsSearchResult.title"};
    const JSTISettingsSearchResult invalid{"\xFF", "Detail", "settingsSearchResult.title"};
    bool okay = jsti_window_set_settings_search_results(tooMany.data(), tooMany.size()) == -1 &&
        jsti_window_set_settings_search_results(&missing, 1) == -1 &&
        jsti_window_set_settings_search_results(&invalid, 1) == -1 &&
        jsti_window_set_settings_search_results(nullptr, 1) == -1 &&
        jsti_window_reveal_configuration_field(static_cast<size_t>(-1)) == -1;
    HWND edit = GetDlgItem(window, settingsSearchID), list = GetDlgItem(window, settingsResultsID);
    SetWindowTextW(edit, L"mic");
    okay = okay && observed.event == JSTI_EVENT_SETTINGS_SEARCH && observed.text == "mic";
    const JSTISettingsSearchResult rows[] = {
        {"Microphone", "General - The input device.", "settingsSearchResult.general.microphone"},
        {"Model", "Transcription - The transcription model.", "settingsSearchResult.desktop.model"}};
    okay = jsti_window_set_settings_search_results(rows, 2) == 0 && okay;
    SendMessageW(window, settingsSearchMessage, 0, 0);
    wchar_t name[128]{};
    if (SendMessageW(list, LB_GETTEXTLEN, 1, 0) < 128) SendMessageW(list, LB_GETTEXT, 1, reinterpret_cast<LPARAM>(name));
    okay = okay && SendMessageW(list, LB_GETCOUNT, 0, 0) == 2 && visible(settingsResultsID) &&
        !visible(settingsNoMatchID) && !visible(navBaseID) &&
        std::wstring(name) == L"Model, Transcription - The transcription model.";
    SendMessageW(list, LB_SETCURSEL, 1, 0);
    MSG enter{};
    enter.hwnd = list; enter.message = WM_KEYDOWN; enter.wParam = VK_RETURN;
    okay = okay && settingsSearchKeyMessage(window, enter) && observed.event == JSTI_EVENT_SETTINGS_SEARCH_OPEN &&
        observed.row == 1 && observed.text == "settingsSearchResult.desktop.model" &&
        GetWindowTextLengthW(edit) == 0 && !visible(settingsResultsID) && visible(navBaseID);
    settingsSearch.focusPage = false;
    SetWindowTextW(edit, L"zzzz");
    okay = jsti_window_set_settings_search_results(nullptr, 0) == 0 && okay;
    SendMessageW(window, settingsSearchMessage, 0, 0);
    okay = okay && visible(settingsNoMatchID) && !visible(settingsResultsID) && !visible(navBaseID) &&
        controlText(GetDlgItem(window, settingsNoMatchID)) == L"No settings match";
    closeSettingsSearch(window, true);
    okay = okay && !visible(settingsNoMatchID) && visible(navBaseID);
    state.callback = originalCallback;
    state.context = originalContext;
    if (originalFocus && IsWindowVisible(originalFocus)) SetFocus(originalFocus);
    return okay;
}

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
    if (state.aboutLinks.size() != 6 || controlText(GetDlgItem(window, aboutDetailsID)) != state.aboutDetails ||
        state.aboutDetails.find(L"Version:") == std::wstring::npos ||
        jsti_window_configure_about("late", &lateAboutLink, 1) != -1 ||
        jsti_window_configure_about("late", nullptr, 0) != -1)
        return jsti::fail("About metadata, canonical links or invalid input refusal failed.", error, errorCapacity);
    for (size_t i = 0; i < state.aboutLinks.size(); ++i) {
        HWND button = GetDlgItem(window, aboutLinkBaseID + static_cast<int>(i));
        if (!button || controlText(button) != state.aboutLinks[i].title ||
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
    {
        const JSTIVisualDensity saved = visualDensity;
        JSTIVisualDensity normal = saved;
        normal.compact = 0;
        const JSTIVisualDensity compact{1, 8, 6, 8, 6, 6, 8, 30};
        DensityDelivery startup;
        bool okay = true;
        for (const auto &density : {normal, compact}) {
            okay = configureVisualDensity(startup, nullptr, density) == 0 && okay;
            const auto *retained = startup.initial.get();
            JSTIVisualDensity invalid = density;
            invalid.compact = 2;
            okay = configureVisualDensity(startup, nullptr, invalid) == -1 &&
                startup.initial.get() == retained && okay;
            auto admitted = startup.claimInitial();
            okay = okay && admitted && admitted->compact == density.compact &&
                admitted->page_padding == density.page_padding && !startup.initial;
        }
        const int originalPage = state.page;
        HWND originalFocus = GetFocus();
        const LRESULT font = SendDlgItemMessageW(window, transcriptID, WM_GETFONT, 0, 0);
        HWND edit = CreateWindowExW(0, L"EDIT", L"Unchanged density draft", WS_CHILD | WS_VISIBLE,
            0, 0, 120, 34, window, nullptr, GetModuleHandleW(nullptr), nullptr);
        auto apply = [&](const JSTIVisualDensity &density) {
            UINT_PTR token = 0;
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                if (configureVisualDensity(state.densityDelivery, window, density) != 0) return false;
                token = state.densityDelivery.sequence;
            }
            SendMessageW(window, densityMessage, token, 0);
            return true;
        };
        okay = okay && edit != nullptr && font != 0;
        for (int page = 0; page < pageCount; ++page) {
            showPage(window, page);
            okay = apply(normal) && okay;
            const auto baseline = placed;
            const auto cards = frame.cards;
            const RECT hero = frame.hero;
            const RECT lastRow = placed.at(navBaseID + pageCount - 1);
            okay = okay && frame.sidebar.right == measuredSidebarWidth(window) &&
                frame.sidebar.right >= scale(window, 232) &&
                heightOf(placed.at(navBaseID)) == scale(window, 36);
            if (edit) SetFocus(edit);
            okay = apply(compact) && okay;
            okay = okay && heightOf(placed.at(navBaseID)) == scale(window, 36) &&
                placed.at(navBaseID + pageCount - 1).top < lastRow.top &&
                SendDlgItemMessageW(window, transcriptID, WM_GETFONT, 0, 0) == font &&
                GetFocus() == edit && controlText(edit) == L"Unchanged density draft";
            if (hero.right > hero.left) {
                okay = okay && hero.left == frame.sidebar.right + scale(window, 24) &&
                    frame.hero.left == frame.sidebar.right + scale(window, 8);
            }
            for (const auto &card : frame.cards) {
                const RECT body = cardBody(window, card.rect);
                okay = okay && body.left - card.rect.left == scale(window, 8) &&
                    body.top - card.rect.top == scale(window, 52) &&
                    card.rect.bottom - body.bottom == scale(window, 8);
            }
            okay = apply(normal) && okay;
            okay = okay && cards.size() == frame.cards.size() && EqualRect(&hero, &frame.hero);
            for (size_t index = 0; index < cards.size() && index < frame.cards.size(); ++index)
                okay = okay && EqualRect(&cards[index].rect, &frame.cards[index].rect);
            for (const auto &control : baseline)
                okay = okay && EqualRect(&control.second, &placed.at(control.first));
        }
        okay = apply(saved) && okay;
        if (edit) DestroyWindow(edit);
        showPage(window, originalPage);
        if (originalFocus && IsWindowVisible(originalFocus)) SetFocus(originalFocus);
        if (!okay) return jsti::fail("Layout density geometry, Normal restoration or editing focus failed.",
                                     error, errorCapacity);
    }
    {
        const auto saved = state.sidebar;
        const int page = state.page;
        HWND focus = GetFocus();
        state.sidebar = SidebarBindings();
        state.sidebar.digits[dashboardPage] = 1;
        state.sidebar.hints[dashboardPage] = L"Ctrl+1";
        state.sidebar.showHints = true;
        applySidebarBindings(window);
        const bool reserved = jsti_hotkey_reserves_sidebar_digit(1);
        const std::wstring expected = reserved ? L"Dashboard" : L"Dashboard (Ctrl+1)";
        bool okay = controlText(GetDlgItem(window, navBaseID)) == expected;
        showPage(window, historyPage);
        okay = okay && !navigateSidebar(window, 9, true, window) && state.page == historyPage &&
            !navigateSidebar(window, 1, false, window) && state.page == historyPage;
        HWND edit = CreateWindowExW(0, L"EDIT", L"Unchanged", WS_CHILD, 0, 0, 10, 10,
                                    window, nullptr, GetModuleHandleW(nullptr), nullptr);
        okay = okay && edit && !navigateSidebar(window, 1, true, edit) && state.page == historyPage;
        if (edit) DestroyWindow(edit);
        HWND row = GetDlgItem(window, navBaseID);
        EnableWindow(row, FALSE);
        okay = okay && !navigateSidebar(window, 1, true, window) && state.page == historyPage;
        EnableWindow(row, TRUE);
        state.sidebar.showHints = false;
        applySidebarBindings(window);
        okay = okay && controlText(row) == L"Dashboard";
        const bool routed = navigateSidebar(window, 1, true, window);
        okay = okay && (reserved ? !routed && state.page == historyPage : routed && state.page == dashboardPage);
        state.sidebar = saved;
        applySidebarBindings(window);
        showPage(window, page);
        if (focus && IsWindowVisible(focus)) SetFocus(focus);
        if (!okay) return jsti::fail("Sidebar hints, focus guards or window-local navigation failed.", error, errorCapacity);
    }
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
    std::pair<int, std::wstring> originalLogin;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        originalLogin = {state.loginItem, state.loginItemDetail};
    }
    const auto originalCallback = state.callback;
    void *const originalContext = state.context;
    RECT originalBounds{};
    GetWindowRect(window, &originalBounds);
    // The model, source and mode checks read the Transcription page's controls.
    const int originalPage = state.page;
    showPage(window, transcriptionPage);
    struct Event { int event = 0; std::string id; int model = -1; int calls = 0; } observed;
    state.callback = [](int event, const char *id, int model, void *context) {
        auto &observed = *static_cast<Event *>(context);
        observed.event = event; observed.id = id ? id : ""; observed.model = model; ++observed.calls;
    };
    state.context = &observed;
    const unsigned originalAbsence = handsFreeAbsence.exchange(0);
    SendMessageW(window, WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0);
    const bool lockEvent = observed.calls == 1 && observed.event == JSTI_EVENT_USER_ABSENT && !observed.id.empty();
    SendMessageW(window, WM_POWERBROADCAST, PBT_APMSUSPEND, 0);
    const bool suspendEvent = observed.calls == 2 && observed.event == JSTI_EVENT_USER_ABSENT && !observed.id.empty();
    SendMessageW(window, WM_WTSSESSION_CHANGE, WTS_SESSION_UNLOCK, 0);
    const bool stayedSuspended = handsFreeAbsence == 2u && !jsti_window_hands_free_guard_ready();
    SendMessageW(window, WM_POWERBROADCAST, PBT_APMRESUMEAUTOMATIC, 0);
    const bool guardCleared = handsFreeAbsence == 0;
    handsFreeAbsence = originalAbsence;
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
            reportOwned = state.migrationReport == L"Synthetic read-only report.";
            state.migrationReport.clear(); // Do not open a modal report in the automated fixture.
        }
        if (!reportOwned) { failure = "Backup inspection report did not own its posted text."; return false; }
        observed = {};
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
        // Launch at login shows what the host reports, cannot be changed while
        // the system decides it, and reports one click until the host answers.
        {
            showPage(window, generalPage);
            HWND toggle = GetDlgItem(window, loginItemID);
            auto shows = [&](bool on) { return (GetWindowLongPtrW(toggle, GWLP_USERDATA) != 0) == on; };
            jsti_window_set_login_item(jsti::login::offBySystem, "Turned off in Settings.");
            applyUpdate(window);
            const bool decided = !IsWindowEnabled(toggle) && shows(false) &&
                                 state.loginItemNote == L"Turned off in Settings." && checkBounds();
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
            const bool settled = IsWindowEnabled(toggle) && shows(true) && state.loginItemNote.empty();
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
        state.modelNames = {L"Remote Batch", L"Remote Live", L"Local Batch", L"Local Live",
                            L"Imported Local Batch", L"Imported Local Live"};
        state.modelModes = {0, 1, 2, 3, 2, 3};
        state.modelOrder = {0, 1, 2, 3, 4, 5};
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.knownModelIdentities = {{"remote-batch", 0}, {"remote-live", 1}, {"local-batch", 2},
                                         {"local-live", 3}, {"other-batch", 2}, {"other-live", 3}};
        }
        state.preferredModels[3] = 3;
        if (!populateModels(window)) { failure = "Local transfer fixture could not display models."; return false; }
        const int beforeImport = observed.event = -500;
        if (jsti_window_set_local_model_preferences(4, -1) != 0 ||
            jsti_window_set_local_model_preferences(-1, 5) != 0) {
            failure = "Inactive Local choices could not be published."; return false;
        }
        applyUpdate(window);
        if (selection(window) != 0 || observed.event != beforeImport || state.preferredModels[0] != 0 ||
            state.preferredModels[1] != 1 || state.preferredModels[2] != 4 || state.preferredModels[3] != 5 ||
            !changeSource(1, 4) || !changeMode(1, 5) || jsti_window_set_local_model_preferences(2, 3) != 0) {
            failure = "Local transfer activated a model or lost an inactive preference."; return false;
        }
        observed.event = -500;
        applyUpdate(window);
        if (selection(window) != 5 || observed.event != -500 || state.preferredModels[3] != 5 ||
            state.preferredModels[2] != 2 ||
            jsti_window_set_local_model_preferences(-2, -1) != -1 ||
            jsti_window_set_local_model_preferences(1, 2) != -1 || !changeSource(0, 1)) {
            failure = "Local transfer replaced the active model or accepted a wrong-mode index."; return false;
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
        state.loginItem = originalLogin.first;
        state.loginItemDetail = originalLogin.second;
        state.loginItemPending = false;
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
