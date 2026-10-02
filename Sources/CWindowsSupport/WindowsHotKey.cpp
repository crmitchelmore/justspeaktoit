#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commctrl.h>
#include <cwctype>
#include <mutex>
#include <set>
#include <vector>

// The global recording shortcut and its native Shortcut dialog. A
// press-to-toggle style keeps the original behaviour: each press toggles
// recording. Gesture styles report the press and the release to the host,
// which classifies hold, tap and double-tap with the shared SpeakCore gesture
// machine and asks for its one deadline timer here. RegisterHotKey reports only
// presses, so the release is observed by polling the key state while the key
// is held; nothing polls while it is up and no keyboard hook is installed.

// Provided by WindowsWindow.cpp.
void jsti_window_hotkey_event(HWND window, int event);
int jsti_window_recording_state();

namespace {
constexpr int hotkeyID = 1, candidateID = 2;
constexpr UINT_PTR releaseTimer = 0x4A51, deadlineTimer = 0x4A52;
constexpr UINT releasePollMilliseconds = 15;
constexpr UINT fallbackModifiers = MOD_CONTROL | MOD_ALT, fallbackKey = VK_SPACE;

struct Configuration {
    UINT modifiers = fallbackModifiers, key = fallbackKey;
    std::vector<std::wstring> names, descriptions;
    int style = 0, pressStyle = 0;
    JSTIHotKeySettingsCallback callback = nullptr;
    void *context = nullptr;
    bool gestures() const { return !names.empty() && style != pressStyle; }
};
std::mutex configurationMutex;
Configuration configuration;

// UI thread only.
struct Runtime {
    HWND window = nullptr;
    bool registered = false, held = false;
    UINT modifiers = fallbackModifiers, key = fallbackKey;
    BOOL (WINAPI *registerKey)(HWND, int, UINT, UINT) = RegisterHotKey;
    BOOL (WINAPI *unregisterKey)(HWND, int) = UnregisterHotKey;
    SHORT (WINAPI *keyState)(int) = GetAsyncKeyState;
} runtime;

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

bool modifierKey(UINT key) {
    switch (key) {
    case VK_SHIFT: case VK_CONTROL: case VK_MENU: case VK_LSHIFT: case VK_RSHIFT: case VK_LCONTROL:
    case VK_RCONTROL: case VK_LMENU: case VK_RMENU: case VK_LWIN: case VK_RWIN: case VK_CAPITAL:
    case VK_NUMLOCK: case VK_SCROLL: return true;
    default: return false;
    }
}

bool validCombination(UINT modifiers, UINT key) {
    return key > 0 && key < 0xFF && !modifierKey(key) && !(modifiers & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT)) &&
        (modifiers & (MOD_ALT | MOD_CONTROL));
}

std::wstring keyName(UINT key) {
    UINT scan = MapVirtualKeyW(key, MAPVK_VK_TO_VSC);
    switch (key) {
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_PRIOR: case VK_NEXT: case VK_END:
    case VK_HOME: case VK_INSERT: case VK_DELETE: case VK_DIVIDE: case VK_NUMLOCK: scan |= 0x100; break;
    default: break;
    }
    wchar_t text[64] = {};
    if (scan && GetKeyNameTextW(static_cast<LONG>(scan << 16), text, 64) > 0) return text;
    wchar_t fallback[16] = {};
    std::swprintf(fallback, 16, L"Key 0x%02X", key);
    return fallback;
}

std::wstring comboName(UINT modifiers, UINT key) {
    std::wstring name;
    if (modifiers & MOD_CONTROL) name += L"Ctrl+";
    if (modifiers & MOD_ALT) name += L"Alt+";
    if (modifiers & MOD_SHIFT) name += L"Shift+";
    return name + keyName(key);
}

void stopRelease(HWND window) {
    if (window) {
        KillTimer(window, releaseTimer);
        KillTimer(window, deadlineTimer);
    }
    runtime.held = false;
}

// Probes availability on a separate identifier first, so a refused
// combination never releases the working one.
bool registerCombination(HWND window, UINT modifiers, UINT key) {
    if (!runtime.registerKey(window, candidateID, modifiers | MOD_NOREPEAT, key)) return false;
    runtime.unregisterKey(window, candidateID);
    if (runtime.registered) runtime.unregisterKey(window, hotkeyID);
    if (runtime.registerKey(window, hotkeyID, modifiers | MOD_NOREPEAT, key)) {
        runtime.registered = true;
        runtime.modifiers = modifiers;
        runtime.key = key;
        return true;
    }
    runtime.registered = runtime.registerKey(window, hotkeyID, runtime.modifiers | MOD_NOREPEAT, runtime.key) != 0;
    return false;
}

// ---- Shortcut dialog -------------------------------------------------------

enum Control { introID = 800, keyLabelID, keyID, styleLabelID, styleID, descriptionID, statusID };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 520, minimumClientHeight = 340;

struct Dialog {
    Configuration config;
    HWND owner = nullptr;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool applied = false;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), row = at(28), button = at(32), gap = at(10), buttonWidth = at(100);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, at(16), width, at(44));
    move(keyLabelID, margin, at(66), width, at(22));
    move(keyID, margin, at(90), width, row);
    move(styleLabelID, margin, at(128), width, at(22));
    move(styleID, margin, at(152), width, at(200));
    move(descriptionID, margin, at(188), width, at(46));
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    move(statusID, margin, at(240), width, std::max(at(22), top - gap - at(240)));
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

int selectedStyle(HWND window) {
    return static_cast<int>(SendDlgItemMessageW(window, styleID, CB_GETCURSEL, 0, 0));
}

void describe(HWND window, const Dialog &dialog) {
    const int style = selectedStyle(window);
    const bool valid = style >= 0 && static_cast<size_t>(style) < dialog.config.descriptions.size();
    SetDlgItemTextW(window, descriptionID, valid ? dialog.config.descriptions[static_cast<size_t>(style)].c_str() : L"");
}

WORD hotkeyValue(UINT modifiers, UINT key) {
    BYTE flags = 0;
    if (modifiers & MOD_SHIFT) flags |= HOTKEYF_SHIFT;
    if (modifiers & MOD_CONTROL) flags |= HOTKEYF_CONTROL;
    if (modifiers & MOD_ALT) flags |= HOTKEYF_ALT;
    return MAKEWORD(static_cast<BYTE>(key), flags);
}

bool createControls(HWND window, Dialog &dialog) {
    INITCOMMONCONTROLSEX classes{sizeof(classes), ICC_HOTKEY_CLASS};
    if (!InitCommonControlsEx(&classes)) return false;
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Choose the global shortcut and how it controls recording. It works while other apps "
            L"are in front.", SS_LEFT, introID) &&
        add(L"STATIC", L"&Shortcut (press the keys)", 0, keyLabelID) &&
        add(HOTKEY_CLASSW, L"", WS_TABSTOP | WS_BORDER, keyID) &&
        add(L"STATIC", L"&Activation", 0, styleLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, styleID) &&
        add(L"STATIC", L"", SS_LEFT, descriptionID) &&
        add(L"STATIC", L"", SS_LEFT, statusID) &&
        add(L"BUTTON", L"A&pply", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    // Shift-only and unmodified keys would capture ordinary typing everywhere.
    SendDlgItemMessageW(window, keyID, HKM_SETRULES, HKCOMB_NONE | HKCOMB_S, MAKELPARAM(HOTKEYF_CONTROL | HOTKEYF_ALT, 0));
    SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(dialog.config.modifiers, dialog.config.key), 0);
    for (const auto &name : dialog.config.names) {
        const LRESULT added = SendDlgItemMessageW(window, styleID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
    }
    SendDlgItemMessageW(window, styleID, CB_SETCURSEL, static_cast<WPARAM>(dialog.config.style), 0);
    refreshFont(window, dialog);
    describe(window, dialog);
    layout(window);
    return true;
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

void apply(HWND window, Dialog &dialog) {
    if (dialog.applied) return;
    const WORD value = static_cast<WORD>(SendDlgItemMessageW(window, keyID, HKM_GETHOTKEY, 0, 0));
    const UINT key = LOBYTE(value), flags = HIBYTE(value);
    const UINT modifiers = ((flags & HOTKEYF_ALT) ? MOD_ALT : 0) | ((flags & HOTKEYF_CONTROL) ? MOD_CONTROL : 0) |
        ((flags & HOTKEYF_SHIFT) ? MOD_SHIFT : 0);
    const int style = selectedStyle(window);
    if (!validCombination(modifiers, key)) {
        SetDlgItemTextW(window, statusID, L"Choose a key together with Ctrl or Alt, for example Ctrl+Alt+Space.");
        return;
    }
    if (style < 0 || static_cast<size_t>(style) >= dialog.config.names.size()) {
        SetDlgItemTextW(window, statusID, L"Choose how the shortcut starts and stops recording.");
        return;
    }
    const bool changed = modifiers != runtime.modifiers || key != runtime.key || !runtime.registered;
    if (changed && !registerCombination(dialog.owner, modifiers, key)) {
        const std::wstring message = comboName(modifiers, key) +
            L" is already used by Windows or another app. Choose another shortcut.";
        SetDlgItemTextW(window, statusID, message.c_str());
        return;
    }
    dialog.applied = true;
    // A style change ends any press in progress; the host resets its gestures.
    stopRelease(dialog.owner);
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.modifiers = modifiers;
        configuration.key = key;
        configuration.style = style;
    }
    if (dialog.config.callback) dialog.config.callback(modifiers, key, style, dialog.config.context);
    close(window);
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
        if (LOWORD(wparam) == WA_INACTIVE) { dialog->focus = GetFocus(); return 0; }
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, keyID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
        if (LOWORD(wparam) == styleID && HIWORD(wparam) == CBN_SELCHANGE) { describe(window, *dialog); return 0; }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog); return 0; }
        if (LOWORD(wparam) == IDCANCEL) { close(window); return 0; }
        return 0;
    case WM_CLOSE: close(window); return 0;
    case WM_DESTROY:
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
    type.lpszClassName = L"JustSpeakToItShortcut";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 540), scale(owner, 360)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    dialog.owner = owner;
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Shortcut — Just Speak to It", windowStyle,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}
} // namespace

// ---- window integration ----------------------------------------------------

bool jsti_hotkey_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr && !configuration.names.empty();
}

std::wstring jsti_hotkey_label() {
    const Configuration config = snapshot();
    const std::wstring name = comboName(runtime.registered ? runtime.modifiers : config.modifiers,
                                        runtime.registered ? runtime.key : config.key);
    if (config.names.empty() || config.style < 0 || static_cast<size_t>(config.style) >= config.names.size()) {
        return L"Transcript — " + name + L" starts or stops recording";
    }
    return L"Transcript — " + name + L" (" + config.names[static_cast<size_t>(config.style)] + L")";
}

// Registers the configured shortcut when the window starts. On failure the
// window stays usable through its Record button and the message names the key.
bool jsti_hotkey_start(HWND window, std::string &failure) {
    const Configuration config = snapshot();
    runtime.window = window;
    runtime.registered = false;
    runtime.held = false;
    runtime.modifiers = config.modifiers;
    runtime.key = config.key;
    if (runtime.registerKey(window, hotkeyID, config.modifiers | MOD_NOREPEAT, config.key)) {
        runtime.registered = true;
        return true;
    }
    failure = jsti::utf8(comboName(config.modifiers, config.key)) +
        " is unavailable. Another app may own it; choose another in Shortcut or use Record in this window.";
    return false;
}

void jsti_hotkey_stop(HWND window) {
    stopRelease(window);
    if (runtime.registered) runtime.unregisterKey(window, hotkeyID);
    runtime.registered = false;
    runtime.window = nullptr;
}

// WM_HOTKEY and WM_TIMER from the main window. Returns true when handled.
bool jsti_hotkey_message(HWND window, UINT message, WPARAM wparam) {
    if (message == WM_HOTKEY) {
        if (wparam != hotkeyID) return false;
        if (!snapshot().gestures()) {
            jsti_window_hotkey_event(window, JSTI_EVENT_TOGGLE_RECORDING);
            return true;
        }
        // A modal dialog disables the owner; transcription owns the session.
        if (runtime.held || !IsWindowEnabled(window) || jsti_window_recording_state() == 2) return true;
        runtime.held = true;
        jsti_window_hotkey_event(window, JSTI_EVENT_HOTKEY_DOWN);
        if (runtime.held && !SetTimer(window, releaseTimer, releasePollMilliseconds, nullptr)) {
            runtime.held = false;
            jsti_window_hotkey_event(window, JSTI_EVENT_HOTKEY_UP);
        }
        return true;
    }
    if (message != WM_TIMER) return false;
    if (wparam == releaseTimer) {
        if (runtime.held && (runtime.keyState(static_cast<int>(runtime.key)) & 0x8000)) return true;
        KillTimer(window, releaseTimer);
        if (!runtime.held) return true;
        runtime.held = false;
        jsti_window_hotkey_event(window, JSTI_EVENT_HOTKEY_UP);
        return true;
    }
    if (wparam == deadlineTimer) {
        KillTimer(window, deadlineTimer);
        jsti_window_hotkey_event(window, JSTI_EVENT_HOTKEY_DEADLINE);
        return true;
    }
    return false;
}

void jsti_show_hotkey_settings(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback || dialog.config.names.empty()) return;
    if (runtime.registered) {
        dialog.config.modifiers = runtime.modifiers;
        dialog.config.key = runtime.key;
    }
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening shortcut settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, keyID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading shortcut settings messages").c_str(), nullptr, -1);
}

int jsti_window_set_hotkey(unsigned modifiers, unsigned virtualKey, const char *const *styleNames,
                           const char *const *styleDescriptions, size_t styleCount, int style, int pressStyle,
                           JSTIHotKeySettingsCallback callback, void *context) {
    if (!callback || !styleNames || !styleDescriptions || !styleCount || styleCount > 16 ||
        !validCombination(modifiers, virtualKey) || style < 0 || static_cast<size_t>(style) >= styleCount ||
        pressStyle < 0 || static_cast<size_t>(pressStyle) >= styleCount) return -1;
    try {
        Configuration updated;
        for (size_t index = 0; index < styleCount; ++index) {
            std::wstring name, description;
            if (!jsti::wide(styleNames[index], name) || !jsti::wide(styleDescriptions[index], description) ||
                name.empty() || name.size() > 128 || description.size() > 1024) return -1;
            updated.names.push_back(std::move(name));
            updated.descriptions.push_back(std::move(description));
        }
        updated.modifiers = modifiers;
        updated.key = virtualKey;
        updated.style = style;
        updated.pressStyle = pressStyle;
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_hotkey(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

int jsti_window_set_hotkey_deadline(int milliseconds) {
    const HWND window = runtime.window;
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) return -1;
    if (milliseconds < 0) { KillTimer(window, deadlineTimer); return 0; }
    return SetTimer(window, deadlineTimer, static_cast<UINT>(std::max(milliseconds, static_cast<int>(USER_TIMER_MINIMUM))),
                    nullptr) ? 0 : -1;
}

int jsti_hotkey_name(unsigned modifiers, unsigned virtualKey, char *name, size_t capacity) {
    if (!name || !capacity || !validCombination(modifiers, virtualKey)) return -1;
    const std::string text = jsti::utf8(comboName(modifiers, virtualKey));
    if (text.size() >= capacity) return -1;
    std::memcpy(name, text.c_str(), text.size() + 1);
    return 0;
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Fixture {
    std::set<std::pair<UINT, UINT>> taken;
    std::vector<std::pair<int, std::pair<UINT, UINT>>> registered;
    bool keyDown = false;
    int applies = 0;
    unsigned lastModifiers = 0, lastKey = 0;
    int lastStyle = -1;
} *fixture = nullptr;

BOOL WINAPI fakeRegister(HWND, int id, UINT modifiers, UINT key) {
    const auto combination = std::make_pair(modifiers & ~static_cast<UINT>(MOD_NOREPEAT), key);
    if (fixture->taken.count(combination)) return FALSE;
    for (const auto &entry : fixture->registered) if (entry.first == id) return FALSE;
    fixture->registered.push_back({id, combination});
    return TRUE;
}

BOOL WINAPI fakeUnregister(HWND, int id) {
    auto &entries = fixture->registered;
    const auto before = entries.size();
    entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const auto &entry) { return entry.first == id; }),
                  entries.end());
    return entries.size() != before;
}

SHORT WINAPI fakeKeyState(int) { return fixture->keyDown ? static_cast<SHORT>(0x8000) : 0; }

void recordApply(unsigned modifiers, unsigned key, int style, void *) {
    ++fixture->applies;
    fixture->lastModifiers = modifiers;
    fixture->lastKey = key;
    fixture->lastStyle = style;
}

bool registeredAs(UINT modifiers, UINT key) {
    return fixture->registered.size() == 1 && fixture->registered.front().first == hotkeyID &&
        fixture->registered.front().second == std::make_pair(modifiers, key);
}

void clickButton(HWND window, int id) {
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
}
} // namespace

// Drives registration, the dialog and press/release reporting against fake
// registration and key state: no global shortcut is taken and no key is read.
// observe(context) returns the last event the main window emitted.
bool jsti_hotkey_self_test(HWND owner, int (*observe)(void *), void *context, std::string &error) {
    const Configuration original = snapshot();
    const Runtime originalRuntime = runtime;
    Fixture local;
    fixture = &local;
    runtime.registerKey = fakeRegister;
    runtime.unregisterKey = fakeUnregister;
    runtime.keyState = fakeKeyState;
    auto check = [&]() -> bool {
        const char *names[] = {"Toggle", "Hold", "Tap"};
        const char *descriptions[] = {"Each press toggles.", "Hold to record.", "Double tap."};
        if (jsti_window_set_hotkey(MOD_SHIFT, 'R', names, descriptions, 3, 0, 0, recordApply, nullptr) != -1 ||
            jsti_window_set_hotkey(MOD_CONTROL, VK_CONTROL, names, descriptions, 3, 0, 0, recordApply, nullptr) != -1 ||
            jsti_window_set_hotkey(MOD_CONTROL, 'R', names, descriptions, 3, 3, 0, recordApply, nullptr) != -1 ||
            jsti_window_set_hotkey(MOD_CONTROL | MOD_ALT, VK_SPACE, names, descriptions, 3, 0, 0, recordApply, nullptr) != 0) {
            error = "Shortcut configuration accepted an unsafe combination or rejected the default."; return false;
        }
        char name[64] = {};
        if (jsti_hotkey_name(MOD_CONTROL | MOD_ALT, VK_SPACE, name, sizeof(name)) != 0 ||
            std::string(name).rfind("Ctrl+Alt+", 0) != 0) {
            error = "The shortcut name did not list its modifiers."; return false;
        }
        std::string failure;
        jsti_hotkey_stop(owner);
        local.registered.clear();
        if (!jsti_hotkey_start(owner, failure) || !registeredAs(MOD_CONTROL | MOD_ALT, VK_SPACE)) {
            error = "The configured shortcut was not registered at start."; return false;
        }
        // Press-to-toggle keeps the native toggle event.
        SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
        if (observe(context) != JSTI_EVENT_TOGGLE_RECORDING) {
            error = "A press-to-toggle shortcut did not toggle recording."; return false;
        }
        // A taken combination is refused and the working one stays registered.
        local.taken.insert({MOD_CONTROL | MOD_SHIFT, 'K'});
        Dialog dialog;
        dialog.config = snapshot();
        HWND window = createDialog(owner, dialog);
        if (!window) { error = jsti::systemError("Creating the shortcut fixture"); return false; }
        SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(MOD_CONTROL | MOD_SHIFT, 'K'), 0);
        SendDlgItemMessageW(window, styleID, CB_SETCURSEL, 1, 0);
        clickButton(window, IDOK);
        const bool refusedOpen = IsWindow(window) != FALSE;
        wchar_t status[256] = {};
        GetDlgItemTextW(window, statusID, status, 256);
        if (!refusedOpen || local.applies != 0 || !registeredAs(MOD_CONTROL | MOD_ALT, VK_SPACE) ||
            std::wstring(status).find(L"already used") == std::wstring::npos) {
            if (IsWindow(window)) DestroyWindow(window);
            error = "A taken shortcut closed the dialog, changed registration or was not explained."; return false;
        }
        // An available combination and a gesture style apply together.
        SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(MOD_CONTROL | MOD_ALT, 'J'), 0);
        clickButton(window, IDOK);
        const bool applied = !IsWindow(window);
        if (IsWindow(window)) DestroyWindow(window);
        if (!applied || local.applies != 1 || local.lastModifiers != (MOD_CONTROL | MOD_ALT) || local.lastKey != 'J' ||
            local.lastStyle != 1 || !registeredAs(MOD_CONTROL | MOD_ALT, 'J') || !snapshot().gestures()) {
            error = "Applying an available shortcut did not register it and report one complete change."; return false;
        }
        // Gesture styles report the press, then the release seen by polling.
        local.keyDown = true;
        SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
        const int down = observe(context);
        SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
        SendMessageW(owner, WM_TIMER, releaseTimer, 0);
        const int stillDown = observe(context);
        local.keyDown = false;
        SendMessageW(owner, WM_TIMER, releaseTimer, 0);
        const int up = observe(context);
        const bool released = !runtime.held;
        if (down != JSTI_EVENT_HOTKEY_DOWN || stillDown != JSTI_EVENT_HOTKEY_DOWN || up != JSTI_EVENT_HOTKEY_UP ||
            !released) {
            error = "A gesture shortcut did not report exactly one press and its release."; return false;
        }
        if (jsti_window_set_hotkey_deadline(20) != 0) { error = "The gesture deadline could not be armed."; return false; }
        SendMessageW(owner, WM_TIMER, deadlineTimer, 0);
        if (observe(context) != JSTI_EVENT_HOTKEY_DEADLINE || jsti_window_set_hotkey_deadline(-1) != 0) {
            error = "The gesture deadline did not report its expiry."; return false;
        }
        // A disabled owner (modal dialog) ignores presses.
        EnableWindow(owner, FALSE);
        const int beforeModal = observe(context);
        local.keyDown = true;
        SendMessageW(owner, WM_HOTKEY, hotkeyID, 0);
        EnableWindow(owner, TRUE);
        local.keyDown = false;
        if (observe(context) != beforeModal || runtime.held) {
            error = "A gesture press was reported behind a modal dialog."; return false;
        }
        return true;
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { error = "The shortcut self-test could not allocate its fixtures."; }
    stopRelease(owner);
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    runtime = originalRuntime;
    fixture = nullptr;
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
