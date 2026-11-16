// Navigation: page switching, sidebar shortcuts, settings search and cancel keys.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {
namespace {
// Rows are delivered under `mutex`; the rest is UI-thread only. `shown`
// matches the results list row for row.
struct SettingsSearch {
    std::mutex mutex;
    std::vector<SettingsSearchRow> pending;
    bool changed = false, posted = false;
    std::vector<SettingsSearchRow> shown;
    // The box or list has focus and wants results; `suppress` silences
    // programmatic edits; `focusPage` moves focus to the page a choice opens.
    bool active = false, suppress = false, focusPage = false;
};
SettingsSearch settingsSearch;
} // namespace

bool settingsSearchOpen(HWND window) {
    return settingsSearch.active &&
        (!settingsSearch.shown.empty() || GetWindowTextLengthW(GetDlgItem(window, settingsSearchID)) > 0);
}

const SettingsSearchRow *settingsSearchRow(size_t index) {
    return index < settingsSearch.shown.size() ? &settingsSearch.shown[index] : nullptr;
}

bool takeSettingsSearchFocusPage() {
    const bool requested = settingsSearch.focusPage;
    settingsSearch.focusPage = false;
    return requested;
}

bool settingsSearchSuppressed() { return settingsSearch.suppress; }

void retireSettingsSearch() {
    {
        std::lock_guard<std::mutex> lock(settingsSearch.mutex);
        settingsSearch.pending.clear();
        settingsSearch.changed = settingsSearch.posted = false;
    }
    settingsSearch.shown.clear();
    settingsSearch.active = settingsSearch.focusPage = false;
}

void showPage(HWND window, int page) {
    if (page < 0 || page >= pageCount) return;
    const int previous = state.page;
    if (previous != page) retireCleanupPreview();
    state.page = page;
    // A control on the page being left keeps no keyboard focus, and focus on the
    // sidebar (or nowhere) follows the page so a screen reader announces it.
    HWND focus = GetFocus();
    layout(window);
    const bool sidebar = focus && GetDlgCtrlID(focus) >= navBaseID && GetDlgCtrlID(focus) < navBaseID + pageCount &&
        GetParent(focus) == window;
    const bool hidden = focus && IsChild(window, focus) && !IsWindowVisible(focus);
    if (hidden || sidebar || ((!focus || focus == window) && GetActiveWindow() == window))
        SetFocus(GetDlgItem(window, navBaseID + page));
    for (int index : {previous, page}) InvalidateRect(GetDlgItem(window, navBaseID + index), nullptr, TRUE);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

void applySidebarBindings(HWND window, const SidebarBindings &bindings) {
    for (int page = 0; page < pageCount; ++page) {
        std::wstring label = pageInfo[page].title;
        if (bindings.showHints && !bindings.hints[page].empty() &&
            !jsti_hotkey_reserves_sidebar_digit(bindings.digits[page]))
            label += L" (" + bindings.hints[page] + L")";
        SetWindowTextW(GetDlgItem(window, navBaseID + page), label.c_str());
        InvalidateRect(GetDlgItem(window, navBaseID + page), nullptr, TRUE);
    }
}

void applySidebarBindings(HWND window) { applySidebarBindings(window, state.sidebar); }

// --------------------------------------------------------- settings search

// The results (or "No results") replace the sidebar's pages while the
// search is open; choosing, Escape or leaving the search restores them.
void refreshSettingsSearch(HWND window) {
    const bool open = settingsSearchOpen(window);
    bool changed = false;
    auto want = [&](int identifier, bool shown) {
        const auto found = state.wanted.find(identifier);
        if (found != state.wanted.end() && found->second == shown) return;
        state.wanted[identifier] = shown;
        changed = true;
    };
    want(settingsResultsID, open && !settingsSearch.shown.empty());
    want(settingsNoMatchID, open && settingsSearch.shown.empty());
    for (int page = 0; page < pageCount; ++page) want(navBaseID + page, !open);
    if (changed) layout(window);
}

// Every edit, and focusing the box, reports the whole query; the host answers
// with jsti_window_set_settings_search_results (recent destinations when empty).
void emitSettingsSearch(HWND window) {
    if (settingsSearch.suppress) return;
    settingsSearch.active = true;
    settingsSearch.focusPage = false;
    const std::string query = jsti::utf8(controlText(GetDlgItem(window, settingsSearchID)));
    emit(window, JSTI_EVENT_SETTINGS_SEARCH, query.c_str());
}

void closeSettingsSearch(HWND window, bool clear) {
    settingsSearch.active = false;
    if (clear) {
        settingsSearch.suppress = true;
        SetDlgItemTextW(window, settingsSearchID, L"");
        settingsSearch.suppress = false;
        settingsSearch.shown.clear();
        SendDlgItemMessageW(window, settingsResultsID, LB_RESETCONTENT, 0, 0);
    }
    refreshSettingsSearch(window);
}

// Posted on focus loss: the search stays open while the box or its list has focus.
void leaveSettingsSearch(HWND window) {
    const HWND focus = GetFocus();
    if (!settingsSearch.active || focus == GetDlgItem(window, settingsSearchID) ||
        focus == GetDlgItem(window, settingsResultsID)) return;
    closeSettingsSearch(window, false);
}

void applySettingsResults(HWND window) {
    std::vector<SettingsSearchRow> rows;
    {
        std::lock_guard<std::mutex> lock(settingsSearch.mutex);
        settingsSearch.posted = false;
        if (!settingsSearch.changed) return;
        settingsSearch.changed = false;
        rows.swap(settingsSearch.pending);
    }
    HWND list = GetDlgItem(window, settingsResultsID);
    const bool listFocused = GetFocus() == list;
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    settingsSearch.shown.clear();
    for (auto &row : rows) {
        // The item text is its accessible name: "<title>, <detail>".
        const std::wstring name = row.detail.empty() ? row.title : row.title + L", " + row.detail;
        const LRESULT added = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        if (added == LB_ERR || added == LB_ERRSPACE) break;
        settingsSearch.shown.push_back(std::move(row));
    }
    // LB_RESETCONTENT already cleared the selection. LB_SETCURSEL(-1) on an
    // unfocused list raises a focus event for a row, which screen readers then
    // speak while the user is still typing in the search box.
    if (listFocused && !settingsSearch.shown.empty()) SendMessageW(list, LB_SETCURSEL, 0, 0);
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    if (listFocused && settingsSearch.shown.empty()) {
        settingsSearch.suppress = true;
        SetFocus(GetDlgItem(window, settingsSearchID));
        settingsSearch.suppress = false;
    }
    refreshSettingsSearch(window);
    // Typing gives no other cue that the results changed, so a screen reader
    // hears the count (or that nothing matches) for each finished query.
    HWND edit = GetDlgItem(window, settingsSearchID), focus = GetFocus();
    if (settingsSearch.active && (focus == edit || focus == list) && GetWindowTextLengthW(edit) > 0) {
        const size_t count = settingsSearch.shown.size();
        jsti::accessibility::announce(edit, settingsSearchSummary(count), false);
    }
}

std::wstring settingsSearchSummary(size_t count) {
    if (count == 0) return L"No results";
    return std::to_wstring(count) + (count == 1 ? L" result found" : L" results found");
}

// Clears and closes the search, then reports the chosen row; the host opens its
// page (focus follows to that page's sidebar entry) and may reveal a preference.
void chooseSettingsResult(HWND window, LRESULT row) {
    if (row < 0 || static_cast<size_t>(row) >= settingsSearch.shown.size()) return;
    const std::string identifier = settingsSearch.shown[static_cast<size_t>(row)].identifier;
    closeSettingsSearch(window, true);
    SetFocus(GetDlgItem(window, navBaseID + state.page));
    settingsSearch.focusPage = true;
    if (state.callback) state.callback(JSTI_EVENT_SETTINGS_SEARCH_OPEN, identifier.c_str(), static_cast<int>(row),
                                       state.context);
}

void focusSearch(HWND window, int identifier) {
    HWND target = GetDlgItem(window, identifier);
    if (!target || !IsWindowVisible(target) || !IsWindowEnabled(target)) return;
    SetFocus(target);
    SendMessageW(target, EM_SETSEL, 0, -1);
}

// Ctrl+K searches settings from anywhere in the window. Ctrl+F does too, except
// on History, where it finds in History. Down, Up, Enter and Escape move between
// the box and its results, choose one, or back out.
bool settingsSearchKeyMessage(HWND window, const MSG &message) {
    if (message.message != WM_KEYDOWN || !IsWindowEnabled(window) ||
        !(message.hwnd == window || IsChild(window, message.hwnd))) return false;
    const bool control = (GetKeyState(VK_CONTROL) & 0x8000) != 0, alt = (GetKeyState(VK_MENU) & 0x8000) != 0,
        shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0,
        windows = (GetKeyState(VK_LWIN) & 0x8000) != 0 || (GetKeyState(VK_RWIN) & 0x8000) != 0;
    if (control && !alt && !shift && !windows && (message.wParam == 'K' || message.wParam == 'F')) {
        const bool history = message.wParam == 'F' && state.page == historyPage;
        focusSearch(window, history ? searchID : settingsSearchID);
        return true;
    }
    if (control || alt || windows) return false;
    HWND edit = GetDlgItem(window, settingsSearchID), list = GetDlgItem(window, settingsResultsID);
    const bool listed = IsWindowVisible(list) != FALSE && !settingsSearch.shown.empty();
    // The results replace the sidebar's pages, so Tab onward from the search
    // would skip them and forward Tab could never reach the sidebar. Leaving
    // the search restores the pages first; the query stays for Shift+Tab back.
    if (message.wParam == VK_TAB && !shift && settingsSearchOpen(window) &&
        ((message.hwnd == edit && !listed) || message.hwnd == list)) {
        closeSettingsSearch(window, false);
        HWND next = GetNextDlgTabItem(window, message.hwnd, FALSE);
        SetFocus(next && next != message.hwnd ? next : GetDlgItem(window, navBaseID));
        return true;
    }
    if (message.hwnd == edit) {
        switch (message.wParam) {
        case VK_DOWN:
            if (!listed) return false;
            SetFocus(list);
            SendMessageW(list, LB_SETCURSEL, 0, 0);
            return true;
        case VK_RETURN:
            if (listed) chooseSettingsResult(window, 0);
            return true;
        case VK_ESCAPE:
            // The first Escape clears the query (showing recents); the next leaves.
            if (GetWindowTextLengthW(edit) > 0) SetWindowTextW(edit, L"");
            else {
                closeSettingsSearch(window, true);
                SetFocus(GetDlgItem(window, navBaseID + state.page));
            }
            return true;
        default: return false;
        }
    }
    if (message.hwnd != list) return false;
    const LRESULT row = SendMessageW(list, LB_GETCURSEL, 0, 0);
    switch (message.wParam) {
    case VK_RETURN: chooseSettingsResult(window, row == LB_ERR ? 0 : row); return true;
    case VK_ESCAPE: SetFocus(edit); return true;
    case VK_UP:
        if (row != LB_ERR && row > 0) return false;
        SetFocus(edit);
        return true;
    default: return false;
    }
}

// A click chooses the row under the pointer once the list has seen the release.
bool settingsSearchMouseMessage(HWND window, MSG &message) {
    HWND list = GetDlgItem(window, settingsResultsID);
    if (message.message != WM_LBUTTONUP || message.hwnd != list || !list) return false;
    const LRESULT hit = SendMessageW(list, LB_ITEMFROMPOINT, 0, message.lParam);
    DispatchMessageW(&message);
    if (HIWORD(hit) == 0) chooseSettingsResult(window, static_cast<LRESULT>(LOWORD(hit)));
    return true;
}

bool navigateSidebar(HWND window, int digit, bool exactControl, HWND focused) {
    if (!exactControl || digit < 0 || digit > 9 || !IsWindowEnabled(window) ||
        jsti_hotkey_reserves_sidebar_digit(digit)) return false;
    for (HWND focus = focused; focus && focus != window; focus = GetParent(focus)) {
        wchar_t name[128]{};
        GetClassNameW(focus, name, 128);
        if (_wcsicmp(name, L"Edit") == 0 || _wcsicmp(name, L"ComboBox") == 0 ||
            _wcsnicmp(name, L"RichEdit", 8) == 0) return false;
    }
    for (int page = 0; page < pageCount; ++page) {
        HWND row = GetDlgItem(window, navBaseID + page);
        if (state.sidebar.digits[page] == digit && IsWindowEnabled(row) && IsWindowVisible(row)) {
            showPage(window, page);
            return true;
        }

    }
    return false;
}

bool sidebarKeyMessage(HWND window, const MSG &message) {
    if (message.message != WM_KEYDOWN || message.wParam < '0' || message.wParam > '9' ||
        !(message.hwnd == window || IsChild(window, message.hwnd))) return false;
    const bool exactControl = (GetKeyState(VK_CONTROL) & 0x8000) &&
        !(GetKeyState(VK_MENU) & 0x8000) && !(GetKeyState(VK_SHIFT) & 0x8000) &&
        !(GetKeyState(VK_LWIN) & 0x8000) && !(GetKeyState(VK_RWIN) & 0x8000);
    return navigateSidebar(window, static_cast<int>(message.wParam - '0'), exactControl, GetFocus());
}

bool cancelKey(HWND window, const MSG &message, bool plain, bool active) {
    if (message.wParam != VK_ESCAPE || !active || !IsWindowEnabled(window) ||
        !(message.hwnd == window || IsChild(window, message.hwnd))) return false;
    if (message.message == WM_KEYUP || message.message == WM_SYSKEYUP) {
        const bool held = state.cancelKeyHeld;
        state.cancelKeyHeld = false;
        return held && jsti::globalEscape::enabled();
    }
    if (message.message != WM_KEYDOWN) return false;
    if (!jsti::globalEscape::enabled()) {
        if (plain) state.cancelKeyHeld = true;
        return false;
    }
    if (state.cancelKeyHeld) return true;
    if (!plain) return false;
    if (message.lParam & (static_cast<LPARAM>(1) << 30)) return false;
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    if (recording != 1 && recording != 2) return false;
    const auto token = jsti::globalEscape::token();
    if (!token) return false;
    state.cancelKeyHeld = true;
    retireCleanupPreview();
    emit(window, JSTI_EVENT_CANCEL_TRANSCRIPTION, std::to_string(token).c_str());
    return true;
}

bool cancelKeyMessage(HWND window, const MSG &message) {
    if (message.wParam != VK_ESCAPE) return false;
    const bool plain = !(GetKeyState(VK_CONTROL) & 0x8000) && !(GetKeyState(VK_MENU) & 0x8000) &&
        !(GetKeyState(VK_SHIFT) & 0x8000) && !(GetKeyState(VK_LWIN) & 0x8000) &&
        !(GetKeyState(VK_RWIN) & 0x8000);
    return cancelKey(window, message, plain, GetForegroundWindow() == window);
}
} // namespace jsti_window

int jsti_window_set_settings_search_results(const JSTISettingsSearchResult *results, size_t count) {
    if ((count && !results) || count > maximumSettingsResults) return -1;
    try {
        std::vector<SettingsSearchRow> rows;
        rows.reserve(count);
        for (size_t index = 0; index < count; ++index) {
            const auto &result = results[index];
            SettingsSearchRow row;
            std::wstring identifier;
            if (!jsti::wide(result.title, row.title) || !jsti::wide(result.detail, row.detail) ||
                !jsti::wide(result.identifier, identifier) || row.title.empty() || row.title.size() > 256 ||
                row.detail.size() > 1024 || identifier.empty() || identifier.size() > 256) return -1;
            row.identifier = result.identifier;
            rows.push_back(std::move(row));
        }
        std::lock_guard<std::mutex> windowLock(state.mutex);
        if (!state.window) return -1;
        std::lock_guard<std::mutex> lock(settingsSearch.mutex);
        settingsSearch.pending = std::move(rows);
        settingsSearch.changed = true;
        if (!settingsSearch.posted) settingsSearch.posted = PostMessageW(state.window, settingsSearchMessage, 0, 0) != FALSE;
        return settingsSearch.posted ? 0 : -1;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_reveal_configuration_field(size_t index) {
    if (!jsti_configuration_field_available(index)) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.window && PostMessageW(state.window, revealFieldMessage, static_cast<WPARAM>(index), 0) ? 0 : -1;
}
