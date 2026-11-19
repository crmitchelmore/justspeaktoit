#include "WindowsTextOutputSettingsInternal.hpp"
#include "WindowsWindowChrome.hpp"

// Native Text output settings: the output method, insertion mode and clipboard
// restoration used by recordings started after Apply. Standard radio buttons,
// group boxes and a checkbox keep keyboard, contrast and screen reader
// behaviour native. Choices that do not apply to the selected method are
// disabled but kept, so switching back restores them.

using namespace jsti::textOutputSettings;

using jsti::chrome::scale;

namespace {
constexpr UINT probeMessage = WM_APP + 71;
constexpr UINT_PTR probeTimer = 71;

// Self-test only, UI thread: armed by armProbe, run by the next modal loop.
struct Probe {
    bool (*check)(HWND owner, void *context) = nullptr;
    void *context = nullptr;
    bool armed = false, opened = false, passed = false, timedOut = false;
} probe;
} // namespace

namespace jsti::textOutputSettings {

void armProbe(bool (*check)(HWND owner, void *context), void *context) {
    probe = Probe();
    probe.check = check;
    probe.context = context;
    probe.armed = true;
}

ProbeResult takeProbe() {
    const ProbeResult result{probe.opened, probe.passed, probe.timedOut};
    probe = Probe();
    return result;
}

RECT fitWorkArea(RECT proposed, const RECT &work) {
    const LONG width = std::min(proposed.right - proposed.left, work.right - work.left);
    const LONG height = std::min(proposed.bottom - proposed.top, work.bottom - work.top);
    const LONG left = std::clamp(proposed.left, work.left, work.right - width);
    const LONG top = std::clamp(proposed.top, work.top, work.bottom - height);
    return {left, top, left + width, top + height};
}

static RECT availableWorkArea(HWND window) {
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

static void setTabStop(HWND control, bool enabled) {
    const LONG_PTR style = GetWindowLongPtrW(control, GWL_STYLE);
    const LONG_PTR updated = enabled ? (style | WS_TABSTOP) : (style & ~static_cast<LONG_PTR>(WS_TABSTOP));
    if (updated != style) SetWindowLongPtrW(control, GWL_STYLE, updated);
}

// The dialog's draft is the only source of truth. Tab reaches the checked
// option of each group; arrow keys move within the group.
static void render(HWND window, const Dialog &dialog) {
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

static void refreshFont(HWND window, Dialog &dialog) { jsti::chrome::refreshDialogFont(window, dialog.controls, dialog.font); }

static bool createControls(HWND window, Dialog &dialog) {
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
static void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

// A click on a disabled option (for example a programmatic one) never changes
// the stored choice; render restores what the draft holds.
static void choose(HWND window, Dialog &dialog, int id) {
    const HWND control = GetDlgItem(window, id);
    if (control && IsWindowEnabled(control)) {
        if (id >= smartID && id <= clipboardID) dialog.choice.method = id - smartID;
        else if (id >= cursorID && id <= replaceID) dialog.choice.insertion = id - cursorID;
        else if (id == restoreID) dialog.choice.restore = IsDlgButtonChecked(window, restoreID) == BST_CHECKED;
    }
    render(window, dialog);
}

static void apply(HWND window, Dialog &dialog) {
    if (dialog.applied) return;
    dialog.applied = true;
    deliverApply(dialog.config, dialog.choice, dialog.appSwitchSelection);
    close(window);
}

static void runProbe(HWND window, const Dialog &dialog) {
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

static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = jsti::chrome::dialogInstance<Dialog>(window, message, lparam);
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
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
} // namespace jsti::textOutputSettings

void jsti_show_text_output(HWND owner) {
    Dialog dialog;
    dialog.config = configurationSnapshot();
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
