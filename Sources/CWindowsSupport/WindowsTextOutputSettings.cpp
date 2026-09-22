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
    insertionGroupID, cursorID, replaceID, restoreID
};
constexpr UINT probeMessage = WM_APP + 71;
constexpr UINT_PTR probeTimer = 71;
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 472;

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
    JSTITextOutputSettingsCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;

struct Dialog {
    Configuration config;
    Choice choice;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool applied = false;
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
    const HWND focus = GetFocus();
    if (focus && IsChild(window, focus) && !IsWindowEnabled(focus)) SetFocus(GetDlgItem(window, smartID + choice.method));
}

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), inset = at(14), row = at(26), button = at(32), gap = at(10), buttonWidth = at(100);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, at(20), width, at(44));
    move(methodGroupID, margin, at(72), width, at(108));
    for (int index = 0; index < 3; ++index) move(smartID + index, margin + inset, at(94 + 26 * index), width - 2 * inset, row);
    move(noteID, margin, at(188), width, at(90));
    move(insertionGroupID, margin, at(286), width, at(82));
    for (int index = 0; index < 2; ++index) move(cursorID + index, margin + inset, at(308 + 26 * index), width - 2 * inset, row);
    move(restoreID, margin, at(378), width, row);
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    move(IDOK, static_cast<int>(bounds.right) - margin - 2 * buttonWidth - gap, top, buttonWidth, button);
    move(IDCANCEL, static_cast<int>(bounds.right) - margin - buttonWidth, top, buttonWidth, button);
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
        add(L"BUTTON", L"&Direct insertion only: never use the clipboard", option, directID) &&
        add(L"BUTTON", L"C&opy to the clipboard only: never insert", option, clipboardID) &&
        add(L"STATIC", L"Direct insertion goes only into the field that had focus when recording started, and some "
            L"apps do not support it; Smart then uses a guarded clipboard paste. Recordings started from this window "
            L"have no field, so only Copy to the clipboard delivers them automatically.", SS_LEFT | WS_GROUP, noteID) &&
        add(L"BUTTON", L"Insertion", BS_GROUPBOX, insertionGroupID) &&
        add(L"BUTTON", L"At the &cursor, replacing any selected text", option | WS_GROUP | WS_TABSTOP, cursorID) &&
        add(L"BUTTON", L"Replace the &whole field", option, replaceID) &&
        add(L"BUTTON", L"&Restore the previous clipboard after a Smart paste",
            BS_AUTOCHECKBOX | WS_GROUP | WS_TABSTOP, restoreID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
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
        dialog.config.callback(choice.method, choice.insertion, choice.restore ? 1 : 0, dialog.config.context);
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
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {frame.right - frame.left, frame.bottom - frame.top};
        return 0;
    }
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window); return 0;
    }
    case WM_ACTIVATE:
        // Keep keyboard focus on the dialog's last control across activation.
        if (LOWORD(wparam) == WA_INACTIVE) { dialog->focus = GetFocus(); return 0; }
        if (dialog->focus && IsChild(window, dialog->focus) && IsWindowEnabled(dialog->focus)) SetFocus(dialog->focus);
        else SetFocus(GetDlgItem(window, smartID + dialog->choice.method));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
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
    RECT frame{0, 0, scale(owner, 600), scale(owner, 500)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    const int width = frame.right - frame.left, height = frame.bottom - frame.top;
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    RECT work{0, 0, width, height};
    if (GetMonitorInfoW(MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST), &monitor)) work = monitor.rcWork;
    // Keep the whole dialog on the owner's monitor where it fits.
    const int left = std::clamp(static_cast<int>(bounds.left) + scale(owner, 40), static_cast<int>(work.left),
        std::max(static_cast<int>(work.left), static_cast<int>(work.right) - width));
    const int top = std::clamp(static_cast<int>(bounds.top) + scale(owner, 40), static_cast<int>(work.top),
        std::max(static_cast<int>(work.top), static_cast<int>(work.bottom) - height));
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Text output — Just Speak to It", windowStyle,
        left, top, width, height, owner, nullptr, instance, &dialog);
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
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
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

// ---- self-test -------------------------------------------------------------

namespace {
struct Applied {
    int calls = 0;
    Choice last;
};

void recordApply(int method, int insertion, int restore, void *context) {
    auto &applied = *static_cast<Applied *>(context);
    ++applied.calls;
    applied.last = {method, insertion, restore != 0};
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
    return IsDialogMessageW(window, &message) != FALSE;
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
    // The smallest size a user can drag to, as the window itself reports it.
    MINMAXINFO limits{};
    SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits));
    SetWindowPos(window, nullptr, 0, 0, limits.ptMinTrackSize.x, limits.ptMinTrackSize.y,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    layout(window);
    RECT client{};
    GetClientRect(window, &client);
    const int glyph = scale(window, 24), padding = scale(window, 12);
    for (HWND control : dialog.controls) {
        RECT bounds{};
        GetWindowRect(control, &bounds);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
        const int id = GetDlgCtrlID(control);
        const bool wraps = id == introID || id == noteID;
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
            checkModal(owner, button, setRecording, recordingBlocked, context, applied, error);
    } catch (const std::exception &) { error = "The text output self-test could not allocate its fixtures."; }
    probe = Probe();
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = original; }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
