#include "WindowsTextOutputSettingsInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <cwchar>
#include <cwctype>
#include <set>

// The Text output settings self-test: the configuration ABI, every choice
// combination through the controls, keyboard, bounds at compact sizes and DPI,
// and the owner's modal loop.

using namespace jsti::textOutputSettings;
using jsti::chrome::scale;

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
    // A rejected app-switch policy keeps the previous labels and selection.
    if (jsti_window_set_app_switch("Policy", "First\nSecond", 1, "Help") != 0 ||
        jsti_window_set_app_switch("", "First", 0, "") != -1 ||
        jsti_window_set_app_switch("Policy", "First\n\nSecond", 0, "") != -1 ||
        jsti_window_set_app_switch("Policy", "First\nSecond", 2, "") != -1 ||
        jsti_window_app_switch_selection() != 1 || configurationSnapshot().appSwitchLabels.size() != 2) {
        error = "Text output app-switch settings accepted an invalid policy or lost the previous one."; return false;
    }
    // Clearing drops the borrowed callback and context entirely.
    jsti_window_clear_text_output();
    if (jsti_window_text_output(&method, &insertion, &restore) != -1 || jsti_text_output_available() ||
        !configurationSnapshot().appSwitchLabels.empty() || jsti_window_app_switch_selection() != 0 ||
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
    // The draft's choice is reported only during its Apply callback.
    okay = okay && jsti_window_app_switch_selection() == configurationSnapshot().appSwitchSelection;
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
    const bool openedWhileRecording = takeProbe().opened;
    setRecording(owner, 0);
    const bool availableWhenIdle = IsWindowEnabled(GetDlgItem(owner, button)) != FALSE;
    armProbe(recordingBlocked, context);
    click(owner, button);
    const ProbeResult idle = takeProbe();
    const bool modal = idle.opened && idle.passed && !idle.timedOut;
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
    const Configuration original = configurationSnapshot();
    Applied applied;
    bool passed = false;
    try {
        passed = checkConfiguration(applied, error) && checkChoices(owner, applied, error) &&
            checkCancellationAndKeys(owner, applied, error) && checkKeyboardAndBounds(owner, applied, error) &&
            checkAppSwitchChooser(owner, applied, error) &&
            checkCompactWorkAreaDPI(error) && checkCompactKeyboardReachability(owner, applied, error) &&
            checkModal(owner, button, setRecording, recordingBlocked, context, applied, error);
    } catch (const std::exception &) { error = "The text output self-test could not allocate its fixtures."; }
    takeProbe();
    exchangeConfiguration(original);
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
