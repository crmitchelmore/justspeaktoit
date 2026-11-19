// Independent main window scenarios: sidebar startup retention, App visibility,
// the cleanup preview, settings search, layout density and sidebar navigation.
#include "WindowsWindowSelfTestInternal.hpp"
#include "../CWindowsSupport/WindowsWindowHistoryPage.hpp"
#include "../CWindowsSupport/WindowsWindowModelsPage.hpp"
#include <commctrl.h>

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

// Validation and retention of App visibility, and the owner change that takes
// a window off the taskbar, on a private hidden fixture.
bool shellSelfTest(std::string &failure) {
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

bool cleanupPreviewSelfTest(HWND window) {
    const int page = state.page;
    const bool ready = historyView().historyPresentationReady;
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
    historyView().historyPresentationReady = ready;
    showPage(window, page);
    SetDlgItemTextW(window, transcriptID, originalText.c_str());
    SetDlgItemTextW(window, statusID, originalStatus.c_str());
    updateHistoryControls(window, recording);
    return okay;
}

// Results replace the list and read as "<title>, <detail>"; Enter reports the
// chosen row and closes the search; an empty set says "No results";
// invalid input and an unknown preference are refused.
bool settingsSearchSelfTest(HWND window) {
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
    takeSettingsSearchFocusPage();
    SetWindowTextW(edit, L"zzzz");
    okay = jsti_window_set_settings_search_results(nullptr, 0) == 0 && okay;
    SendMessageW(window, settingsSearchMessage, 0, 0);
    okay = okay && visible(settingsNoMatchID) && !visible(settingsResultsID) && !visible(navBaseID) &&
        controlText(GetDlgItem(window, settingsNoMatchID)) == L"No results";
    closeSettingsSearch(window, true);
    okay = okay && !visible(settingsNoMatchID) && visible(navBaseID);
    state.callback = originalCallback;
    state.context = originalContext;
    if (originalFocus && IsWindowVisible(originalFocus)) SetFocus(originalFocus);
    return okay;
}

// Issue #1400: announcements have a provider UI Automation delivers from, the
// results list has a name, the search reports its count, a read-only transcript
// does not trap Tab, a sidebar page change moves focus to the new page, and
// activation never restores focus to a hidden control.
bool screenReaderSelfTest(HWND window, std::string &failure) {
    const int originalPage = state.page;
    HWND originalFocus = GetFocus();
    bool okay = true;
    auto expect = [&](bool condition, const char *message) {
        if (okay && !condition) { okay = false; failure = message; }
    };
    expect(jsti::accessibility::attached(window),
           "The main window serves no UI Automation provider, so announcements are dropped.");
    expect(settingsSearchSummary(0) == L"No results" && settingsSearchSummary(1) == L"1 result found" &&
               settingsSearchSummary(12) == L"12 results found",
           "Settings search does not summarise its results for screen readers.");
    const JSTISettingsSearchResult rows[] = {
        {"Microphone", "General - The input device.", "settingsSearchResult.general.microphone"}};
    // The query stays here: the host would otherwise answer it with real results.
    const auto originalCallback = state.callback;
    void *const originalContext = state.context;
    state.callback = [](int, const char *, int, void *) {};
    state.context = nullptr;
    SetWindowTextW(GetDlgItem(window, settingsSearchID), L"mic");
    jsti_window_set_settings_search_results(rows, 1);
    // An unfocused list must not be sent LB_SETCURSEL: even -1 raises a focus
    // event for a row, and screen readers speak it over the search box.
    HWND results = GetDlgItem(window, settingsResultsID);
    int selections = 0;
    const SUBCLASSPROC countSelections = [](HWND list, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR,
                                            DWORD_PTR data) -> LRESULT {
        if (message == LB_SETCURSEL && GetFocus() != list) ++*reinterpret_cast<int *>(data);
        return DefSubclassProc(list, message, wparam, lparam);
    };
    if (GetFocus() == results) SetFocus(GetDlgItem(window, settingsSearchID));
    SetWindowSubclass(results, countSelections, 0x1400, reinterpret_cast<DWORD_PTR>(&selections));
    SendMessageW(window, settingsSearchMessage, 0, 0);
    RemoveWindowSubclass(results, countSelections, 0x1400);
    expect(selections == 0, "Settings search sent the unfocused results list a selection, which is announced.");
    std::string auditFailure;
    expect((GetWindowLongW(GetDlgItem(window, settingsResultsID), GWL_STYLE) & WS_VISIBLE) != 0,
           "Settings results did not open for the name check.");
    expect(jsti::accessibility::audit(window, auditFailure) > 0, "The open settings results list has no name.");
    // The results replace the sidebar, so Tab out of the search must restore
    // the page buttons and land on the first, or forward Tab never reaches them.
    SetFocus(results);
    MSG forward{};
    forward.hwnd = results; forward.message = WM_KEYDOWN; forward.wParam = VK_TAB;
    expect(settingsSearchKeyMessage(window, forward) && GetFocus() == GetDlgItem(window, navBaseID) &&
               (GetWindowLongW(GetDlgItem(window, navBaseID), GWL_STYLE) & WS_VISIBLE) != 0,
           "Tab out of settings search skipped the sidebar pages it had hidden.");
    closeSettingsSearch(window, true);
    state.callback = originalCallback;
    state.context = originalContext;
    HWND transcript = GetDlgItem(window, transcriptID);
    MSG tab{};
    tab.hwnd = transcript; tab.message = WM_KEYDOWN; tab.wParam = VK_TAB;
    const LRESULT code = SendMessageW(transcript, WM_GETDLGCODE, VK_TAB, reinterpret_cast<LPARAM>(&tab));
    expect(jsti::chrome::releasesDialogKeys(transcript) &&
               !(code & (DLGC_WANTTAB | DLGC_WANTALLKEYS | DLGC_WANTMESSAGE)),
           "The read-only transcript still keeps Tab, trapping keyboard focus.");
    showPage(window, dashboardPage);
    SetFocus(GetDlgItem(window, navBaseID + dashboardPage));
    showPage(window, historyPage);
    expect(GetFocus() == GetDlgItem(window, navBaseID + historyPage),
           "A page shortcut left focus on the previous sidebar entry.");
    HWND remembered = GetDlgItem(window, transcriptID);
    showPage(window, aboutPage);
    jsti::chrome::rememberFocus(window, WA_ACTIVE, remembered, navBaseID + aboutPage);
    expect(GetFocus() == GetDlgItem(window, navBaseID + aboutPage),
           "Activation restored focus to a control hidden on another page.");
    showPage(window, originalPage);
    if (originalFocus && IsWindowVisible(originalFocus)) SetFocus(originalFocus);
    return okay;
}

// Layout density geometry, Normal restoration and editing focus, then sidebar
// hints, focus guards and window-local navigation.
bool densityAndSidebarSelfTest(HWND window, std::string &failure) {
    {
        const JSTIVisualDensity saved = currentVisualDensity();
        const Frame &frame = layoutFrame();
        const auto &placed = placedControls();
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
        if (!okay) { failure = "Layout density geometry, Normal restoration or editing focus failed."; return false; }
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
        if (!okay) { failure = "Sidebar hints, focus guards or window-local navigation failed."; return false; }
    }
    return true;
}
} // namespace jsti_window
