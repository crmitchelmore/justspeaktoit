#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <cwchar>
#include <cwctype>
#include <mutex>
#include <set>
#include <vector>

// Native Text output settings: the output method, insertion mode and clipboard
// restoration used by recordings started after Apply. Standard radio buttons,
// group boxes and a checkbox keep keyboard, contrast and screen reader
// behaviour native. Choices that do not apply to the selected method are
// disabled but kept, so switching back restores them.

namespace {
enum Control {
    introID = 700, methodGroupID, smartID, directID, clipboardID, noteID,
    insertionGroupID, cursorID, replaceID, restoreID, appSwitchLabelID, appSwitchID, appSwitchHelpID
};
constexpr UINT probeMessage = WM_APP + 71;
constexpr UINT_PTR probeTimer = 71;
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VSCROLL;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 260, preferredClientHeight = 670;

struct Choice {
    int method = JSTI_TEXT_OUTPUT_SMART;
    int insertion = JSTI_TEXT_OUTPUT_AT_CURSOR;
    bool restore = true;
    bool operator==(const Choice &other) const {
        return method == other.method && insertion == other.insertion && restore == other.restore;
    }
};
struct Configuration {
    Choice choice;
    std::wstring appSwitchTitle, appSwitchHelp;
    std::vector<std::wstring> appSwitchLabels;
    int appSwitchSelection = 0;
    JSTITextOutputSettingsCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;
thread_local int applyingAppSwitchSelection = -1;

struct Dialog {
    Configuration config;
    Choice choice;
    int appSwitchSelection = 0;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool applied = false;
    int scroll = 0;
    int wheelRemainder = 0;
};

// Self-test only, UI thread: runs inside the next modal loop after the owner
// has been disabled, then closes the dialog through Escape without applying.
struct Probe {
    bool (*check)(HWND owner, void *context) = nullptr;
    void *context = nullptr;
    bool armed = false, opened = false, passed = false, timedOut = false;
} probe;

void armProbe(bool (*check)(HWND owner, void *context), void *context) {
    probe = Probe();
    probe.check = check;
    probe.context = context;
    probe.armed = true;
}

bool valid(int method, int insertion, int restore) {
    return method >= JSTI_TEXT_OUTPUT_SMART && method <= JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY &&
        (insertion == JSTI_TEXT_OUTPUT_AT_CURSOR || insertion == JSTI_TEXT_OUTPUT_REPLACE_FIELD) &&
        (restore == 0 || restore == 1);
}

// Insertion applies to both inserting methods. Restoration applies only to a
// Smart paste at the cursor: replacing a field and direct insertion never paste.
bool insertionApplies(const Choice &choice) { return choice.method != JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY; }
bool restoreApplies(const Choice &choice) {
    return choice.method == JSTI_TEXT_OUTPUT_SMART && choice.insertion == JSTI_TEXT_OUTPUT_AT_CURSOR;
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

RECT fitWorkArea(RECT proposed, const RECT &work) {
    const LONG width = std::min(proposed.right - proposed.left, work.right - work.left);
    const LONG height = std::min(proposed.bottom - proposed.top, work.bottom - work.top);
    const LONG left = std::clamp(proposed.left, work.left, work.right - width);
    const LONG top = std::clamp(proposed.top, work.top, work.bottom - height);
    return {left, top, left + width, top + height};
}

RECT availableWorkArea(HWND window) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) return monitor.rcWork;
    RECT work{};
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) return work;
    // The virtual screen is still a size bound if work-area discovery fails.
    return {GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
}

void setTabStop(HWND control, bool enabled) {
    const LONG_PTR style = GetWindowLongPtrW(control, GWL_STYLE);
    const LONG_PTR updated = enabled ? (style | WS_TABSTOP) : (style & ~static_cast<LONG_PTR>(WS_TABSTOP));
    if (updated != style) SetWindowLongPtrW(control, GWL_STYLE, updated);
}

// The dialog's draft is the only source of truth. Tab reaches the checked
// option of each group; arrow keys move within the group.
void render(HWND window, const Dialog &dialog) {
    const Choice &choice = dialog.choice;
    CheckRadioButton(window, smartID, clipboardID, smartID + choice.method);
    CheckRadioButton(window, cursorID, replaceID, cursorID + choice.insertion);
    CheckDlgButton(window, restoreID, choice.restore ? BST_CHECKED : BST_UNCHECKED);
    for (int id = smartID; id <= clipboardID; ++id) setTabStop(GetDlgItem(window, id), id == smartID + choice.method);
    for (int id = cursorID; id <= replaceID; ++id) {
        EnableWindow(GetDlgItem(window, id), insertionApplies(choice));
        setTabStop(GetDlgItem(window, id), id == cursorID + choice.insertion);
    }
    EnableWindow(GetDlgItem(window, insertionGroupID), insertionApplies(choice));
    EnableWindow(GetDlgItem(window, restoreID), restoreApplies(choice));
    SendDlgItemMessageW(window, appSwitchID, CB_SETCURSEL, dialog.appSwitchSelection, 0);
    EnableWindow(GetDlgItem(window, appSwitchID), insertionApplies(choice) && !dialog.config.appSwitchLabels.empty());
    const HWND focus = GetFocus();
    if (focus && IsChild(window, focus) && !IsWindowEnabled(focus)) SetFocus(GetDlgItem(window, smartID + choice.method));
}

void layout(HWND window) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!dialog) return;
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), inset = at(14), row = at(26), button = at(32), gap = at(10), buttonWidth = at(100);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto wrappedHeight = [&](int id, int minimum) {
        const HWND control = GetDlgItem(window, id);
        const int length = GetWindowTextLengthW(control);
        std::wstring text(static_cast<size_t>(length) + 1, 0);
        GetWindowTextW(control, &text[0], length + 1);
        const HDC dc = GetDC(control);
        if (!dc) return minimum;
        const HGDIOBJ previous = SelectObject(dc, reinterpret_cast<HGDIOBJ>(SendMessageW(control, WM_GETFONT, 0, 0)));
        RECT needed{0, 0, std::max(1, width), 0};
        DrawTextW(dc, text.c_str(), length, &needed, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
        SelectObject(dc, previous);
        ReleaseDC(control, dc);
        return std::max(minimum, static_cast<int>(needed.bottom));
    };
    const int introHeight = wrappedHeight(introID, at(44));
    const int noteHeight = wrappedHeight(noteID, at(90));
    const int helpHeight = wrappedHeight(appSwitchHelpID, at(110));
    const int afterIntro = introHeight - at(44), afterNote = afterIntro + noteHeight - at(90);
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    const int viewportBottom = std::max(0, top - gap);
    const int contentHeight = at(488) + afterNote + helpHeight + margin;
    dialog->scroll = std::clamp(dialog->scroll, 0, std::max(0, contentHeight - viewportBottom));
    SCROLLINFO scrolling{};
    scrolling.cbSize = sizeof(scrolling);
    scrolling.fMask = SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL;
    scrolling.nMax = contentHeight - 1;
    scrolling.nPage = static_cast<UINT>(viewportBottom);
    scrolling.nPos = dialog->scroll;
    SetScrollInfo(window, SB_VERT, &scrolling, TRUE);
    auto move = [&](int id, int x, int y, int w, int h) {
        const HWND control = GetDlgItem(window, id);
        const bool pinned = id == IDOK || id == IDCANCEL;
        if (!pinned) y -= dialog->scroll;
        MoveWindow(control, x, y, w, h, TRUE);
        if (!pinned) {
            RECT actual{};
            GetWindowRect(control, &actual);
            // Clip the scrollable controls before the pinned action row, including hit testing.
            const int height = actual.bottom - actual.top;
            const int first = std::clamp(-y, 0, height);
            const int last = std::clamp(viewportBottom - y, first, height);
            SetWindowRgn(control, CreateRectRgn(0, first, std::max(0, w), last), TRUE);
        }
    };
    move(introID, margin, at(20), width, introHeight);
    move(methodGroupID, margin, at(72) + afterIntro, width, at(108));
    for (int index = 0; index < 3; ++index)
        move(smartID + index, margin + inset, at(94 + 26 * index) + afterIntro, width - 2 * inset, row);
    move(noteID, margin, at(188) + afterIntro, width, noteHeight);
    move(insertionGroupID, margin, at(286) + afterNote, width, at(82));
    for (int index = 0; index < 2; ++index)
        move(cursorID + index, margin + inset, at(308 + 26 * index) + afterNote, width - 2 * inset, row);
    move(restoreID, margin, at(378) + afterNote, width, row);
    move(appSwitchLabelID, margin, at(420) + afterNote, width, row);
    move(appSwitchID, margin, at(450) + afterNote, width, at(180));
    move(appSwitchHelpID, margin, at(488) + afterNote, width, helpHeight);
    move(IDOK, static_cast<int>(bounds.right) - margin - 2 * buttonWidth - gap, top, buttonWidth, button);
    move(IDCANCEL, static_cast<int>(bounds.right) - margin - buttonWidth, top, buttonWidth, button);
}

void revealControl(HWND window, HWND control) {
    if (!control || GetParent(control) != window) return;
    const int id = GetDlgCtrlID(control);
    if (id == IDOK || id == IDCANCEL) return;
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!dialog) return;
    RECT bounds{}, client{};
    GetWindowRect(control, &bounds);
    MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
    GetClientRect(window, &client);
    const int bottom = std::max(0L, client.bottom - scale(window, 20) - scale(window, 32) - scale(window, 10));
    if (bounds.top < 0) dialog->scroll += bounds.top;
    else if (bounds.bottom > bottom) dialog->scroll += bounds.bottom - bottom;
    else return;
    layout(window);
}

bool routeDialogKey(HWND window, MSG &message) {
    const bool handled = IsDialogMessageW(window, &message) != FALSE;
    if (handled && message.message >= WM_KEYFIRST && message.message <= WM_KEYLAST && IsWindow(window))
        revealControl(window, GetFocus());
    return handled;
}

void refreshFont(HWND window, Dialog &dialog) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return;
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = font;
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    // Creation order is tab order. WS_GROUP bounds each radio group, so the
    // controls following the last option of a group start a new group.
    const DWORD option = BS_AUTORADIOBUTTON;
    const bool okay =
        add(L"STATIC", L"Choose what happens to a finished transcript. Changes apply to recordings you start "
            L"after applying them.", SS_LEFT, introID) &&
        add(L"BUTTON", L"Output method", BS_GROUPBOX, methodGroupID) &&
        add(L"BUTTON", L"&Smart: insert directly, or paste if needed", option | WS_GROUP | WS_TABSTOP, smartID) &&
        add(L"BUTTON", L"&Direct insertion only: never send paste keys", option, directID) &&
        add(L"BUTTON", L"C&opy to the clipboard only: never insert", option, clipboardID) &&
        add(L"STATIC", L"Legacy delivery keeps the captured field. Explicit policies below choose the original field "
            L"or a switched app's field at delivery. Smart may use a guarded paste. Unsupported or unsafe explicit "
            L"destinations copy for recovery, not confirmed insertion. Without an original field, recordings cannot "
            L"retarget.", SS_LEFT | WS_GROUP, noteID) &&
        add(L"BUTTON", L"Insertion", BS_GROUPBOX, insertionGroupID) &&
        add(L"BUTTON", L"At the &cursor, replacing any selected text", option | WS_GROUP | WS_TABSTOP, cursorID) &&
        add(L"BUTTON", L"Replace the &whole field", option, replaceID) &&
        add(L"BUTTON", L"&Restore the previous clipboard after a Smart paste",
            BS_AUTOCHECKBOX | WS_GROUP | WS_TABSTOP, restoreID) &&
        add(L"STATIC", dialog.config.appSwitchTitle.c_str(), SS_LEFT, appSwitchLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP | WS_GROUP, appSwitchID) &&
        add(L"STATIC", dialog.config.appSwitchHelp.c_str(), SS_LEFT, appSwitchHelpID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    for (const auto &label : dialog.config.appSwitchLabels)
        SendDlgItemMessageW(window, appSwitchID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
    refreshFont(window, dialog);
    render(window, dialog);
    layout(window);
    return true;
}

// Re-enable the owner before destruction so Windows activates it, not another app.
void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

// A click on a disabled option (for example a programmatic one) never changes
// the stored choice; render restores what the draft holds.
void choose(HWND window, Dialog &dialog, int id) {
    const HWND control = GetDlgItem(window, id);
    if (control && IsWindowEnabled(control)) {
        if (id >= smartID && id <= clipboardID) dialog.choice.method = id - smartID;
        else if (id >= cursorID && id <= replaceID) dialog.choice.insertion = id - cursorID;
        else if (id == restoreID) dialog.choice.restore = IsDlgButtonChecked(window, restoreID) == BST_CHECKED;
    }
    render(window, dialog);
}

void apply(HWND window, Dialog &dialog) {
    if (dialog.applied) return;
    dialog.applied = true;
    const Choice choice = dialog.choice;
    if (dialog.config.callback) {
        applyingAppSwitchSelection = dialog.appSwitchSelection;
        dialog.config.callback(choice.method, choice.insertion, choice.restore ? 1 : 0, dialog.config.context);
        applyingAppSwitchSelection = -1;
    }
    close(window);
}

void runProbe(HWND window, const Dialog &dialog) {
    if (!probe.check) return;
    const HWND owner = GetWindow(window, GW_OWNER);
    probe.opened = true;
    probe.passed = owner && !IsWindowEnabled(owner) && probe.check(owner, probe.context);
    probe.check = nullptr;
    // Close through the modal loop's own keyboard handling; the timer bounds a
    // missed key so a failure is reported rather than hanging the loop.
    SetTimer(window, probeTimer, 2000, nullptr);
    PostMessageW(GetDlgItem(window, smartID + dialog.choice.method), WM_KEYDOWN, VK_ESCAPE, 1);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return createControls(window, *dialog) ? 0 : -1;
    case WM_GETMINMAXINFO: {
        RECT frame{0, 0, scale(window, minimumClientWidth), scale(window, minimumClientHeight)};
        AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(window));
        const RECT work = availableWorkArea(window);
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {
            std::min(frame.right - frame.left, work.right - work.left),
            std::min(frame.bottom - frame.top, work.bottom - work.top)};
        return 0;
    }
    case WM_SIZE: layout(window); return 0;
    case WM_VSCROLL: {
        SCROLLINFO info{};
        info.cbSize = sizeof(info);
        info.fMask = SIF_ALL;
        GetScrollInfo(window, SB_VERT, &info);
        switch (LOWORD(wparam)) {
        case SB_LINEUP: dialog->scroll -= scale(window, 26); break;
        case SB_LINEDOWN: dialog->scroll += scale(window, 26); break;
        case SB_PAGEUP: dialog->scroll -= static_cast<int>(info.nPage); break;
        case SB_PAGEDOWN: dialog->scroll += static_cast<int>(info.nPage); break;
        case SB_THUMBTRACK: case SB_THUMBPOSITION: dialog->scroll = info.nTrackPos; break;
        case SB_TOP: dialog->scroll = 0; break;
        case SB_BOTTOM: dialog->scroll = info.nMax; break;
        default: return 0;
        }
        layout(window);
        return 0;
    }
    case WM_MOUSEWHEEL:
        dialog->wheelRemainder += GET_WHEEL_DELTA_WPARAM(wparam);
        dialog->scroll -= (dialog->wheelRemainder / WHEEL_DELTA) * scale(window, 78);
        dialog->wheelRemainder %= WHEEL_DELTA;
        layout(window);
        return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        const RECT fitted = fitWorkArea(*bounds, availableWorkArea(window));
        SetWindowPos(window, nullptr, fitted.left, fitted.top, fitted.right - fitted.left,
            fitted.bottom - fitted.top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window);
        revealControl(window, GetFocus()); return 0;
    }
    case WM_ACTIVATE:
        // Keep keyboard focus on the dialog's last control across activation.
        if (LOWORD(wparam) == WA_INACTIVE) { dialog->focus = GetFocus(); return 0; }
        if (dialog->focus && IsChild(window, dialog->focus) && IsWindowEnabled(dialog->focus)) SetFocus(dialog->focus);
        else SetFocus(GetDlgItem(window, smartID + dialog->choice.method));
        revealControl(window, GetFocus());
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
        if (LOWORD(wparam) == appSwitchID && HIWORD(wparam) == CBN_SELCHANGE) {
            const LRESULT selection = SendDlgItemMessageW(window, appSwitchID, CB_GETCURSEL, 0, 0);
            if (IsWindowEnabled(GetDlgItem(window, appSwitchID)) && selection >= 0 &&
                static_cast<size_t>(selection) < dialog->config.appSwitchLabels.size())
                dialog->appSwitchSelection = static_cast<int>(selection);
            render(window, *dialog);
            return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog); return 0; }
        if (LOWORD(wparam) == IDCANCEL) { close(window); return 0; }
        choose(window, *dialog, LOWORD(wparam));
        return 0;
    case probeMessage: runProbe(window, *dialog); return 0;
    case WM_TIMER:
        if (wparam != probeTimer) break;
        KillTimer(window, probeTimer);
        probe.timedOut = true;
        close(window);
        return 0;
    case WM_CLOSE: close(window); return 0;
    case WM_DESTROY:
        KillTimer(window, probeTimer);
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItTextOutput";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 600), scale(owner, preferredClientHeight)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    const int width = frame.right - frame.left, height = frame.bottom - frame.top;
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    const LONG left = bounds.left + scale(owner, 40), top = bounds.top + scale(owner, 40);
    const RECT fitted = fitWorkArea({left, top, left + width, top + height}, availableWorkArea(owner));
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Text output — Just Speak to It", windowStyle,
        fitted.left, fitted.top, fitted.right - fitted.left, fitted.bottom - fitted.top, owner, nullptr, instance, &dialog);
}
} // namespace

bool jsti_text_output_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr;
}

void jsti_show_text_output(HWND owner) {
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(configurationMutex); dialog.config = configuration; }
    if (!dialog.config.callback) return;
    dialog.choice = dialog.config.choice;
    dialog.appSwitchSelection = dialog.config.appSwitchSelection;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening text output settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, smartID + dialog.choice.method));
    if (probe.armed) { probe.armed = false; PostMessageW(window, probeMessage, 0, 0); }
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!routeDialogKey(window, message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading text output settings messages").c_str(), nullptr, -1);
}

int jsti_window_set_text_output(int method, int insertion, int restoreClipboard,
                                JSTITextOutputSettingsCallback callback, void *context) {
    if (!callback || !valid(method, insertion, restoreClipboard)) return -1;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.choice = {method, insertion, restoreClipboard != 0};
        configuration.callback = callback;
        configuration.context = context;
    }
    // Configuration is valid before the main window exists; afterwards this
    // refreshes the button's availability.
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

int jsti_window_text_output(int *method, int *insertion, int *restoreClipboard) {
    if (!method || !insertion || !restoreClipboard) return -1;
    std::lock_guard<std::mutex> lock(configurationMutex);
    if (!configuration.callback) return -1;
    *method = configuration.choice.method;
    *insertion = configuration.choice.insertion;
    *restoreClipboard = configuration.choice.restore ? 1 : 0;
    return 0;
}

int jsti_window_set_app_switch(const char *title, const char *labels, int selection, const char *help) {
    std::wstring wideTitle, wideLabels, wideHelp;
    if (!jsti::wide(title, wideTitle) || !jsti::wide(labels, wideLabels) || !jsti::wide(help, wideHelp)) return -1;
    std::vector<std::wstring> choices;
    size_t start = 0;
    while (start < wideLabels.size()) {
        const size_t end = wideLabels.find(L'\n', start);
        auto value = wideLabels.substr(start, end == std::wstring::npos ? end : end - start);
        if (value.empty()) return -1;
        choices.push_back(std::move(value));
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    if (wideTitle.empty() || choices.empty() || selection < 0 || static_cast<size_t>(selection) >= choices.size()) return -1;
    std::lock_guard<std::mutex> lock(configurationMutex);
    configuration.appSwitchTitle = std::move(wideTitle);
    configuration.appSwitchHelp = std::move(wideHelp);
    configuration.appSwitchLabels = std::move(choices);
    configuration.appSwitchSelection = selection;
    return 0;
}

int jsti_window_app_switch_selection(void) {
    if (applyingAppSwitchSelection >= 0) return applyingAppSwitchSelection;
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.appSwitchSelection;
}

void jsti_window_clear_text_output(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Applied {
    int calls = 0;
    Choice last;
    int appSwitchSelection = -1;
};

void recordApply(int method, int insertion, int restore, void *context) {
    auto &applied = *static_cast<Applied *>(context);
    ++applied.calls;
    applied.last = {method, insertion, restore != 0};
    applied.appSwitchSelection = jsti_window_app_switch_selection();
}

void click(HWND window, int id) {
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
}

// The auto checkbox toggles itself before notifying; emulate that click.
void setRestore(HWND window, bool checked) {
    CheckDlgButton(window, restoreID, checked ? BST_CHECKED : BST_UNCHECKED);
    click(window, restoreID);
}

bool keyboard(HWND window, int id, WPARAM key) {
    MSG message{};
    message.hwnd = GetDlgItem(window, id);
    message.message = WM_KEYDOWN;
    message.wParam = key;
    message.lParam = 1;
    return routeDialogKey(window, message);
}

bool enabled(HWND window, int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; }
bool checked(HWND window, int id) { return IsDlgButtonChecked(window, id) == BST_CHECKED; }
bool tabStop(HWND window, int id) { return (GetWindowLongPtrW(GetDlgItem(window, id), GWL_STYLE) & WS_TABSTOP) != 0; }

// Controls show and retain the draft, including options disabled for it.
bool shows(HWND window, const Choice &choice) {
    for (int method = 0; method < 3; ++method) {
        if (checked(window, smartID + method) != (method == choice.method) ||
            tabStop(window, smartID + method) != (method == choice.method)) return false;
    }
    for (int insertion = 0; insertion < 2; ++insertion) {
        if (checked(window, cursorID + insertion) != (insertion == choice.insertion) ||
            tabStop(window, cursorID + insertion) != (insertion == choice.insertion) ||
            enabled(window, cursorID + insertion) != insertionApplies(choice)) return false;
    }
    return checked(window, restoreID) == choice.restore && enabled(window, restoreID) == restoreApplies(choice) &&
        enabled(window, insertionGroupID) == insertionApplies(choice);
}

HWND openFixture(HWND owner, Dialog &dialog, const Choice &initial, Applied &applied) {
    dialog.config.choice = initial;
    dialog.config.callback = &recordApply;
    dialog.config.context = &applied;
    dialog.choice = initial;
    return createDialog(owner, dialog);
}

bool checkConfiguration(Applied &applied, std::string &error) {
    int method = -1, insertion = -1, restore = -1;
    if (jsti_window_set_text_output(1, 1, 0, &recordApply, &applied) != 0 ||
        jsti_window_text_output(&method, &insertion, &restore) != 0 || method != 1 || insertion != 1 || restore != 0) {
        error = "Text output settings did not accept and report a valid configuration."; return false;
    }
    const int invalid[][3] = {{3, 0, 1}, {-1, 0, 1}, {0, 2, 1}, {0, -1, 1}, {0, 0, 2}, {0, 0, -1}};
    for (const auto &values : invalid) {
        if (jsti_window_set_text_output(values[0], values[1], values[2], &recordApply, &applied) != -1) {
            error = "Text output settings accepted an invalid choice."; return false;
        }
    }
    if (jsti_window_set_text_output(0, 0, 1, nullptr, &applied) != -1 ||
        jsti_window_text_output(nullptr, &insertion, &restore) != -1 ||
        jsti_window_text_output(&method, &insertion, &restore) != 0 || method != 1 || insertion != 1 || restore != 0) {
        error = "A rejected text output configuration replaced the previous one."; return false;
    }
    // Clearing drops the borrowed callback and context entirely.
    jsti_window_clear_text_output();
    if (jsti_window_text_output(&method, &insertion, &restore) != -1 || jsti_text_output_available() ||
        jsti_window_set_text_output(1, 1, 0, &recordApply, &applied) != 0) {
        error = "Clearing text output settings kept a callback or blocked reconfiguration."; return false;
    }
    return true;
}

// Reaches every combination through the controls a user operates: options
// that the final method disables keep the value chosen before switching.
bool checkChoices(HWND owner, Applied &applied, std::string &error) {
    for (int method = 0; method < 3; ++method) {
        for (int insertion = 0; insertion < 2; ++insertion) {
            for (int restore = 0; restore < 2; ++restore) {
                const Choice target{method, insertion, restore != 0};
                Dialog dialog;
                const HWND window = openFixture(owner, dialog, {(method + 1) % 3, 1 - insertion, restore == 0}, applied);
                if (!window) { error = jsti::systemError("Creating the text output fixture"); return false; }
                click(window, smartID);
                click(window, cursorID);
                setRestore(window, target.restore);
                click(window, cursorID + insertion);
                click(window, smartID + method);
                const bool displayed = shows(window, target);
                const int before = applied.calls;
                click(window, IDOK);
                const bool closed = !IsWindow(window);
                if (IsWindow(window)) DestroyWindow(window);
                if (!displayed || !closed || applied.calls != before + 1 || !(applied.last == target)) {
                    error = "Text output Apply did not emit exactly the chosen complete snapshot "
                        "(method " + std::to_string(method) + ", insertion " + std::to_string(insertion) +
                        ", restore " + std::to_string(restore) + ").";
                    return false;
                }
            }
        }
    }
    // Disabled options ignore clicks and keep their stored values.
    Dialog dialog;
    const HWND window = openFixture(owner, dialog, {JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY, 0, true}, applied);
    if (!window) { error = jsti::systemError("Creating the text output fixture"); return false; }
    click(window, replaceID);
    setRestore(window, false);
    const bool ignored = shows(window, {JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY, 0, true});
    click(window, directID);
    setRestore(window, false);
    const bool directIgnoresRestore = shows(window, {JSTI_TEXT_OUTPUT_DIRECT_ONLY, 0, true});
    DestroyWindow(window);
    if (!ignored || !directIgnoresRestore) {
        error = "A disabled text output option changed its stored choice."; return false;
    }
    return true;
}

bool checkCancellationAndKeys(HWND owner, Applied &applied, std::string &error) {
    const int before = applied.calls;
    for (int path = 0; path < 3; ++path) {
        Dialog dialog;
        const HWND window = openFixture(owner, dialog, {}, applied);
        if (!window) { error = jsti::systemError("Creating the text output fixture"); return false; }
        click(window, directID);
        click(window, replaceID);
        if (path == 0) keyboard(window, directID, VK_ESCAPE);
        else if (path == 1) click(window, IDCANCEL);
        else SendMessageW(window, WM_CLOSE, 0, 0);
        const bool closed = !IsWindow(window);
        if (IsWindow(window)) DestroyWindow(window);
        if (!closed || applied.calls != before) {
            error = "Cancelling text output settings emitted a change or left the dialog open."; return false;
        }
    }
    Dialog dialog;
    const HWND window = openFixture(owner, dialog, {JSTI_TEXT_OUTPUT_SMART, 1, false}, applied);
    if (!window) { error = jsti::systemError("Creating the text output fixture"); return false; }
    click(window, clipboardID);
    keyboard(window, clipboardID, VK_RETURN);
    const bool closed = !IsWindow(window);
    if (IsWindow(window)) DestroyWindow(window);
    if (!closed || applied.calls != before + 1 || !(applied.last == Choice{JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY, 1, false})) {
        error = "Enter did not apply one complete text output snapshot."; return false;
    }
    return true;
}

bool checkTraversal(HWND window, const std::vector<int> &expected) {
    HWND current = GetDlgItem(window, expected.front());
    for (size_t index = 1; index <= expected.size(); ++index) {
        current = GetNextDlgTabItem(window, current, FALSE);
        if (current != GetDlgItem(window, expected[index % expected.size()])) return false;
    }
    return true;
}

bool fits(HWND control, bool wraps, int reserved) {
    RECT bounds{};
    GetClientRect(control, &bounds);
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, 0);
    text.resize(static_cast<size_t>(GetWindowTextW(control, &text[0], length + 1)));
    const HDC dc = GetDC(control);
    if (!dc) return false;
    const HGDIOBJ previous = SelectObject(dc, reinterpret_cast<HGDIOBJ>(SendMessageW(control, WM_GETFONT, 0, 0)));
    RECT needed{0, 0, bounds.right - reserved, 0};
    DrawTextW(dc, text.c_str(), -1, &needed, DT_CALCRECT | (wraps ? DT_WORDBREAK : DT_SINGLELINE));
    SelectObject(dc, previous);
    ReleaseDC(control, dc);
    return needed.right <= bounds.right - reserved && needed.bottom <= bounds.bottom;
}

bool checkAppSwitchChooser(HWND owner, Applied &applied, std::string &error) {
    Dialog dialog;
    dialog.config.appSwitchTitle = L"Destination policy";
    dialog.config.appSwitchHelp = L"Unsupported destinations are copied only; intent is retained.";
    dialog.config.appSwitchLabels = {L"Legacy fixture", L"Original fixture", L"Current fixture", L"Copy fixture"};
    dialog.appSwitchSelection = 1;
    const HWND window = openFixture(owner, dialog, {}, applied);
    if (!window) { error = "Could not create the app-switch chooser fixture."; return false; }
    bool okay = enabled(window, appSwitchID) &&
        SendDlgItemMessageW(window, appSwitchID, CB_GETCOUNT, 0, 0) == 4 &&
        SendDlgItemMessageW(window, appSwitchID, CB_GETCURSEL, 0, 0) == 1 &&
        checkTraversal(window, {smartID, cursorID, restoreID, appSwitchID, IDOK, IDCANCEL});
    SendDlgItemMessageW(window, appSwitchID, CB_SETCURSEL, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(appSwitchID, CBN_SELCHANGE), 0);
    click(window, clipboardID);
    okay = okay && !enabled(window, appSwitchID) && dialog.appSwitchSelection == 2;
    click(window, smartID);
    okay = okay && enabled(window, appSwitchID) &&
        SendDlgItemMessageW(window, appSwitchID, CB_GETCURSEL, 0, 0) == 2;
    const int before = applied.calls;
    click(window, IDOK);
    okay = okay && applied.calls == before + 1 && applied.appSwitchSelection == 2 && !IsWindow(window);
    if (IsWindow(window)) DestroyWindow(window);
    if (!okay) error = "App-switch chooser lost its draft, keyboard traversal, disabled retention or Apply selection.";
    return okay;
}

bool checkKeyboardAndBounds(HWND owner, Applied &applied, std::string &error) {
    Dialog dialog;
    const HWND window = openFixture(owner, dialog, {}, applied);
    if (!window) { error = jsti::systemError("Creating the text output fixture"); return false; }
    ShowWindow(window, SW_SHOWNOACTIVATE);
    bool okay = checkTraversal(window, {smartID, cursorID, restoreID, IDOK, IDCANCEL}) &&
        GetNextDlgGroupItem(window, GetDlgItem(window, smartID), FALSE) == GetDlgItem(window, directID) &&
        GetNextDlgGroupItem(window, GetDlgItem(window, clipboardID), FALSE) == GetDlgItem(window, smartID) &&
        GetNextDlgGroupItem(window, GetDlgItem(window, replaceID), FALSE) == GetDlgItem(window, cursorID);
    click(window, replaceID);
    click(window, directID);
    okay = okay && checkTraversal(window, {directID, replaceID, IDOK, IDCANCEL});
    click(window, clipboardID);
    okay = okay && checkTraversal(window, {clipboardID, IDOK, IDCANCEL});
    if (!okay) {
        DestroyWindow(window);
        error = "Text output keyboard traversal skipped or reached an irrelevant option."; return false;
    }
    std::set<wchar_t> mnemonics;
    for (HWND control : dialog.controls) {
        wchar_t text[256]{};
        GetWindowTextW(control, text, 256);
        for (const wchar_t *mark = wcschr(text, L'&'); mark && mark[1]; mark = wcschr(mark + 2, L'&')) {
            if (mark[1] != L'&' && !mnemonics.insert(static_cast<wchar_t>(std::towlower(mark[1]))).second) okay = false;
        }
    }
    click(window, smartID);
    // The minimum viewport preserves full-size labels; each control can scroll into it.
    MINMAXINFO limits{};
    SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits));
    SetWindowPos(window, nullptr, 0, 0, limits.ptMinTrackSize.x, limits.ptMinTrackSize.y,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    layout(window);
    RECT client{};
    GetClientRect(window, &client);
    const int glyph = scale(window, 24), padding = scale(window, 12);
    for (HWND control : dialog.controls) {
        revealControl(window, control);
        RECT bounds{};
        GetWindowRect(control, &bounds);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
        const int id = GetDlgCtrlID(control);
        const bool wraps = id == introID || id == noteID || id == appSwitchHelpID;
        const bool option = (id >= smartID && id <= clipboardID) || id == cursorID || id == replaceID || id == restoreID;
        if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom ||
            bounds.right <= bounds.left || bounds.bottom <= bounds.top ||
            !fits(control, wraps, wraps ? 0 : (option ? glyph : padding))) okay = false;
    }
    auto inside = [&](int group, int first, int last) {
        RECT box{};
        GetWindowRect(GetDlgItem(window, group), &box);
        for (int id = first; id <= last; ++id) {
            RECT bounds{};
            GetWindowRect(GetDlgItem(window, id), &bounds);
            if (bounds.left < box.left || bounds.right > box.right || bounds.top < box.top || bounds.bottom > box.bottom) return false;
        }
        return true;
    };
    okay = okay && inside(methodGroupID, smartID, clipboardID) && inside(insertionGroupID, cursorID, replaceID);
    DestroyWindow(window);
    if (!okay) error = "Text output controls overlap, clip their labels, repeat a mnemonic or leave the minimum bounds.";
    return okay;
}

bool checkCompactWorkAreaDPI(std::string &error) {
    struct Case { int dpi; RECT proposed, work, expected; };
    const Case cases[] = {
        {96, {40, 40, 656, 750}, {0, 0, 1280, 680}, {40, 0, 656, 680}},
        {120, {50, 50, 820, 928}, {0, 0, 1024, 728}, {50, 0, 820, 728}},
        {144, {60, 60, 984, 1115}, {0, 0, 1920, 1040}, {60, 0, 984, 1040}},
        {120, {-950, 50, -180, 928}, {-1024, 0, 0, 728}, {-950, 0, -180, 728}},
        {120, {50, 50, 820, 928}, {0, 0, 640, 440}, {0, 0, 640, 440}}
    };
    for (const auto &test : cases) {
        const RECT result = fitWorkArea(test.proposed, test.work);
        RECT frame{0, 0, MulDiv(600, test.dpi, 96), MulDiv(preferredClientHeight, test.dpi, 96)};
        AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, test.dpi);
        const RECT production = fitWorkArea({test.work.left, test.work.top,
            test.work.left + frame.right - frame.left, test.work.top + frame.bottom - frame.top}, test.work);
        RECT minimum{0, 0, MulDiv(minimumClientWidth, test.dpi, 96), MulDiv(minimumClientHeight, test.dpi, 96)};
        AdjustWindowRectExForDpi(&minimum, windowStyle, FALSE, windowExStyle, test.dpi);
        const RECT minimumBounded = fitWorkArea(minimum, test.work);
        if (!EqualRect(&result, &test.expected) || production.top != test.work.top ||
            production.bottom != test.work.bottom || production.left < test.work.left ||
            production.right > test.work.right || minimumBounded.bottom > test.work.bottom ||
            minimumBounded.top < test.work.top || minimumBounded.right > test.work.right ||
            minimumBounded.left < test.work.left) {
            error = "Text output did not honor exact compact work-area bounds at " + std::to_string(test.dpi) + " DPI.";
            return false;
        }
    }
    return true;
}

bool checkCompactKeyboardReachability(HWND owner, Applied &applied, std::string &error) {
    Dialog dialog;
    dialog.config.appSwitchTitle = L"Destination policy";
    dialog.config.appSwitchHelp = L"Explicit unsupported destinations copy for recovery; intent is retained.";
    dialog.config.appSwitchLabels = {L"Legacy fixture", L"Original fixture", L"Current fixture", L"Copy fixture"};
    const HWND window = openFixture(owner, dialog, {}, applied);
    if (!window) { error = "Could not create the compact text output fixture."; return false; }
    ShowWindow(window, SW_SHOWNOACTIVATE);
    RECT frame{0, 0, scale(window, minimumClientWidth), scale(window, minimumClientHeight)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(window));
    SetWindowPos(window, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    RECT client{};
    GetClientRect(window, &client);
    auto reachable = [&](int id) {
        RECT bounds{};
        GetWindowRect(GetDlgItem(window, id), &bounds);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
        const bool pinned = id == IDOK || id == IDCANCEL;
        return bounds.left >= 0 && bounds.top >= 0 && bounds.right <= client.right &&
            bounds.bottom <= (pinned ? client.bottom :
                client.bottom - scale(window, 20) - scale(window, 32) - scale(window, 10)) &&
            bounds.right > bounds.left && bounds.bottom > bounds.top;
    };
    auto pinnedExactly = [&] {
        RECT apply{}, cancel{};
        GetWindowRect(GetDlgItem(window, IDOK), &apply);
        GetWindowRect(GetDlgItem(window, IDCANCEL), &cancel);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&apply), 2);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&cancel), 2);
        return apply.top == client.bottom - scale(window, 20) - scale(window, 32) &&
            apply.bottom == client.bottom - scale(window, 20) &&
            cancel.top == apply.top && cancel.bottom == apply.bottom &&
            cancel.right == client.right - scale(window, 20) &&
            cancel.left - apply.right == scale(window, 10) && reachable(IDOK) && reachable(IDCANCEL);
    };
    bool okay = pinnedExactly();
    SetFocus(GetDlgItem(window, smartID));
    revealControl(window, GetFocus());
    const int order[] = {smartID, cursorID, restoreID, appSwitchID, IDOK, IDCANCEL, smartID};
    for (size_t index = 0; index + 1 < sizeof(order) / sizeof(order[0]); ++index) {
        okay = okay && GetFocus() == GetDlgItem(window, order[index]) && reachable(order[index]) && pinnedExactly();
        okay = keyboard(window, order[index], VK_TAB) && okay;
        okay = okay && GetFocus() == GetDlgItem(window, order[index + 1]) && reachable(order[index + 1]);
    }
    SetFocus(GetDlgItem(window, appSwitchID));
    revealControl(window, GetFocus());
    const int beforeWheel = dialog.scroll;
    SendMessageW(window, WM_MOUSEWHEEL, MAKEWPARAM(0, WHEEL_DELTA), 0);
    okay = okay && dialog.scroll < beforeWheel && pinnedExactly();
    SendMessageW(window, WM_VSCROLL, SB_BOTTOM, 0);
    okay = okay && reachable(appSwitchID) && pinnedExactly();
    SendMessageW(window, WM_VSCROLL, SB_TOP, 0);
    okay = okay && dialog.scroll == 0 && reachable(smartID) && pinnedExactly();
    revealControl(window, GetDlgItem(window, appSwitchHelpID));
    okay = okay && reachable(appSwitchHelpID) && fits(GetDlgItem(window, appSwitchHelpID), true, 0) && pinnedExactly();
    const int before = applied.calls;
    keyboard(window, appSwitchID, VK_TAB);
    okay = okay && GetFocus() == GetDlgItem(window, IDOK) && pinnedExactly();
    keyboard(window, IDOK, VK_TAB);
    okay = okay && GetFocus() == GetDlgItem(window, IDCANCEL) && pinnedExactly();
    keyboard(window, IDCANCEL, VK_RETURN);
    okay = okay && !IsWindow(window) && applied.calls == before;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog applyDialog;
    applyDialog.config = dialog.config;
    const HWND applyWindow = openFixture(owner, applyDialog, {}, applied);
    if (!applyWindow) { error = "Could not create the compact keyboard Apply fixture."; return false; }
    ShowWindow(applyWindow, SW_SHOWNOACTIVATE);
    SetWindowPos(applyWindow, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    SetFocus(GetDlgItem(applyWindow, appSwitchID));
    revealControl(applyWindow, GetFocus());
    keyboard(applyWindow, appSwitchID, VK_TAB);
    okay = okay && GetFocus() == GetDlgItem(applyWindow, IDOK);
    keyboard(applyWindow, IDOK, VK_RETURN);
    okay = okay && !IsWindow(applyWindow) && applied.calls == before + 1 && applied.last == Choice{} &&
        applied.appSwitchSelection == 0;
    if (IsWindow(applyWindow)) DestroyWindow(applyWindow);
    if (!okay) error = "Compact text output clipped a tab destination, lost scrolling, moved pinned actions or misapplied a draft.";
    return okay;
}

// The owner's own Text output command opens the real modal loop only while
// idle; inside that loop the disabled owner must not start a recording.
bool checkModal(HWND owner, int button, void (*setRecording)(HWND, int),
                bool (*recordingBlocked)(HWND, void *), void *context, Applied &applied, std::string &error) {
    const int before = applied.calls;
    setRecording(owner, 1);
    const bool lockedWhileRecording = !IsWindowEnabled(GetDlgItem(owner, button));
    armProbe(recordingBlocked, context);
    click(owner, button);
    const bool openedWhileRecording = probe.opened;
    probe = Probe();
    setRecording(owner, 0);
    const bool availableWhenIdle = IsWindowEnabled(GetDlgItem(owner, button)) != FALSE;
    armProbe(recordingBlocked, context);
    click(owner, button);
    const bool modal = probe.opened && probe.passed && !probe.timedOut;
    probe = Probe();
    if (!lockedWhileRecording || openedWhileRecording || !availableWhenIdle || !modal ||
        !IsWindowEnabled(owner) || applied.calls != before) {
        error = "The Text output dialog opened while recording, allowed recording behind it, "
            "did not close through Escape or emitted a change.";
        return false;
    }
    return true;
}
} // namespace

bool jsti_text_output_settings_self_test(HWND owner, int button, void (*setRecording)(HWND, int),
                                         bool (*recordingBlocked)(HWND, void *), void *context, std::string &error) {
    Configuration original;
    { std::lock_guard<std::mutex> lock(configurationMutex); original = configuration; }
    Applied applied;
    bool passed = false;
    try {
        passed = checkConfiguration(applied, error) && checkChoices(owner, applied, error) &&
            checkCancellationAndKeys(owner, applied, error) && checkKeyboardAndBounds(owner, applied, error) &&
            checkAppSwitchChooser(owner, applied, error) &&
            checkCompactWorkAreaDPI(error) && checkCompactKeyboardReachability(owner, applied, error) &&
            checkModal(owner, button, setRecording, recordingBlocked, context, applied, error);
    } catch (const std::exception &) { error = "The text output self-test could not allocate its fixtures."; }
    probe = Probe();
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = original; }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
