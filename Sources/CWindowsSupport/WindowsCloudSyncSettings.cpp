#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <shellapi.h>
#include <winhttp.h>
#include <mutex>
#include <vector>

// Native iCloud sync dialog: sign in or out, choose what syncs, sync now.
// The host supplies a snapshot; one button press closes the dialog and calls
// back once on the UI thread. The typed passphrase never outlives the callback.

namespace {
enum Control {
    statusID = 1000, historyID, keysID, passphraseLabelID, passphraseID, noteID, signInID, signOutID, syncNowID
};
enum Action { applyAction = 1, signInAction = 2, signOutAction = 3, syncNowAction = 4 };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 380;

struct Configuration {
    std::wstring status;
    bool available = false, signedIn = false, history = false, keys = false;
    JSTICloudSyncCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;

struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool acted = false;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(32), gap = at(10), width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(statusID, margin, at(14), width, at(48));
    move(historyID, margin, at(70), width, at(24));
    move(keysID, margin, at(100), width, at(24));
    move(passphraseLabelID, margin + at(22), at(130), width - at(22), at(22));
    move(passphraseID, margin + at(22), at(154), width - at(22), at(26));
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    move(noteID, margin, at(190), width, std::max(at(40), top - gap - at(190)));
    const int buttonWidth = (width - 4 * gap) / 5;
    int x = margin;
    const int buttons[] = {signInID, signOutID, syncNowID, IDOK, IDCANCEL};
    for (int id : buttons) {
        move(id, x, top, buttonWidth, button);
        x += buttonWidth + gap;
    }
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

void updateEnabled(HWND window, const Dialog &dialog) {
    const bool usable = dialog.config.available;
    const bool keys = SendDlgItemMessageW(window, keysID, BM_GETCHECK, 0, 0) == BST_CHECKED;
    EnableWindow(GetDlgItem(window, historyID), usable && dialog.config.signedIn);
    EnableWindow(GetDlgItem(window, keysID), usable && dialog.config.signedIn);
    EnableWindow(GetDlgItem(window, passphraseID), usable && dialog.config.signedIn && keys && !dialog.config.keys);
    EnableWindow(GetDlgItem(window, signInID), usable && !dialog.config.signedIn);
    EnableWindow(GetDlgItem(window, signOutID), usable && dialog.config.signedIn);
    EnableWindow(GetDlgItem(window, syncNowID), usable && dialog.config.signedIn);
    EnableWindow(GetDlgItem(window, IDOK), usable && dialog.config.signedIn);
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", dialog.config.status.c_str(), SS_LEFT, statusID) &&
        add(L"BUTTON", L"Sync &History with my Mac through iCloud", BS_AUTOCHECKBOX | WS_TABSTOP | WS_GROUP,
            historyID) &&
        add(L"BUTTON", L"&Import API keys my Mac syncs", BS_AUTOCHECKBOX | WS_TABSTOP, keysID) &&
        add(L"STATIC", L"API-key sync &passphrase (the one set on your Mac)", 0, passphraseLabelID) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP, passphraseID) &&
        add(L"STATIC", L"History syncs transcripts only; audio stays on the device that recorded it. Imported "
            L"keys are saved in Windows Credential Manager and replace keys saved here for the same providers. "
            L"Only a key derived from the passphrase is kept; the passphrase itself is not saved.", SS_LEFT, noteID) &&
        add(L"BUTTON", L"&Sign in…", BS_PUSHBUTTON | WS_TABSTOP | WS_GROUP, signInID) &&
        add(L"BUTTON", L"Sign &out", BS_PUSHBUTTON | WS_TABSTOP, signOutID) &&
        add(L"BUTTON", L"Sync &now", BS_PUSHBUTTON | WS_TABSTOP, syncNowID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    SendDlgItemMessageW(window, passphraseID, EM_LIMITTEXT, 256, 0);
    SendDlgItemMessageW(window, historyID, BM_SETCHECK, dialog.config.history ? BST_CHECKED : BST_UNCHECKED, 0);
    SendDlgItemMessageW(window, keysID, BM_SETCHECK, dialog.config.keys ? BST_CHECKED : BST_UNCHECKED, 0);
    refreshFont(window, dialog);
    layout(window);
    updateEnabled(window, dialog);
    return true;
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

void act(HWND window, Dialog &dialog, int action) {
    if (dialog.acted || !dialog.config.callback) return;
    dialog.acted = true;
    const int history = SendDlgItemMessageW(window, historyID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
    const int keys = SendDlgItemMessageW(window, keysID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
    std::wstring typed(static_cast<size_t>(GetWindowTextLengthW(GetDlgItem(window, passphraseID))) + 1, L'\0');
    GetDlgItemTextW(window, passphraseID, &typed[0], static_cast<int>(typed.size()));
    typed.resize(wcslen(typed.c_str()));
    std::string passphrase = jsti::utf8(typed);
    SecureZeroMemory(&typed[0], typed.size() * sizeof(wchar_t));
    SetDlgItemTextW(window, passphraseID, L"");
    const JSTICloudSyncCallback callback = dialog.config.callback;
    void *context = dialog.config.context;
    close(window);
    callback(action, history, keys, passphrase.c_str(), context);
    if (!passphrase.empty()) SecureZeroMemory(&passphrase[0], passphrase.size());
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
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, IDCANCEL));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        switch (LOWORD(wparam)) {
        case keysID: updateEnabled(window, *dialog); return 0;
        case IDOK: if (IsWindowEnabled(GetDlgItem(window, IDOK))) act(window, *dialog, applyAction); return 0;
        case signInID: act(window, *dialog, signInAction); return 0;
        case signOutID: act(window, *dialog, signOutAction); return 0;
        case syncNowID: act(window, *dialog, syncNowAction); return 0;
        case IDCANCEL: close(window); return 0;
        default: return 0;
        }
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
    type.lpszClassName = L"JustSpeakToItCloudSync";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 600), scale(owner, 400)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"iCloud sync — Just Speak to It", windowStyle,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

bool trustedSignInHost(const std::wstring &host) {
    auto endsWith = [&](const std::wstring &suffix) {
        return host.size() > suffix.size() && host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0;
    };
    std::wstring lower = host;
    for (auto &character : lower) if (character >= L'A' && character <= L'Z') character += L'a' - L'A';
    return lower == L"apple.com" || lower == L"icloud.com" || endsWith(L".apple.com") || endsWith(L".icloud.com");
}
} // namespace

bool jsti_cloud_sync_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr;
}

void jsti_show_cloud_sync_settings(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening iCloud sync settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, IDCANCEL));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading iCloud sync messages").c_str(), nullptr, -1);
}

int jsti_window_set_cloud_sync(const JSTICloudSyncView *view, JSTICloudSyncCallback callback, void *context) {
    if (!view || !callback) return -1;
    try {
        Configuration updated;
        if (view->status && !jsti::wide(view->status, updated.status)) return -1;
        if (updated.status.size() > 1024) updated.status.resize(1024);
        updated.available = view->available != 0;
        updated.signedIn = view->signed_in != 0;
        updated.history = view->history_enabled != 0;
        updated.keys = view->key_import_enabled != 0;
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_cloud_sync(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

int jsti_shell_open_sign_in_page(const char *url, char *error, size_t capacity) {
    std::wstring wide;
    if (!jsti::wide(url, wide) || wide.empty()) return jsti::fail("The sign-in address is invalid.", error, capacity);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUserNameLength = parts.dwPasswordLength = 1;
    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS ||
        parts.dwUserNameLength || parts.dwPasswordLength ||
        !trustedSignInHost(std::wstring(parts.lpszHostName, parts.dwHostNameLength))) {
        return jsti::fail("Only Apple's own sign-in page can be opened.", error, capacity);
    }
    const HINSTANCE result = ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) <= 32) {
        return jsti::fail("Windows could not open the browser for Apple ID sign-in.", error, capacity);
    }
    return 0;
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Acted { int calls = 0, action = 0, history = -1, keys = -1; std::string passphrase; };
void recordAction(int action, int history, int keys, const char *passphrase, void *context) {
    auto &acted = *static_cast<Acted *>(context);
    ++acted.calls;
    acted.action = action;
    acted.history = history;
    acted.keys = keys;
    acted.passphrase = passphrase ? passphrase : "";
}
} // namespace

// Configuration validation, Apply of changed choices with a typed passphrase,
// Close emitting nothing, and refusal of non-Apple sign-in pages.
bool jsti_cloud_sync_settings_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Acted acted;
    bool passed = false;
    try {
        JSTICloudSyncView view{"Signed in to iCloud.", 1, 1, 0, 0};
        char failure[128] = {};
        if (jsti_window_set_cloud_sync(nullptr, recordAction, &acted) != -1 ||
            jsti_window_set_cloud_sync(&view, nullptr, &acted) != -1 ||
            jsti_window_set_cloud_sync(&view, recordAction, &acted) != 0 || !jsti_cloud_sync_available() ||
            jsti_shell_open_sign_in_page("http://idmsa.apple.com/x", failure, sizeof(failure)) != -1 ||
            jsti_shell_open_sign_in_page("https://apple.com.example.net/x", failure, sizeof(failure)) != -1) {
            error = "iCloud sync configuration accepted an invalid view or an untrusted sign-in page.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the iCloud sync fixture");
            } else {
                SendDlgItemMessageW(window, historyID, BM_SETCHECK, BST_CHECKED, 0);
                SendDlgItemMessageW(window, keysID, BM_SETCHECK, BST_CHECKED, 0);
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(keysID, BN_CLICKED), 0);
                const bool passphraseEnabled = IsWindowEnabled(GetDlgItem(window, passphraseID)) != FALSE;
                SetDlgItemTextW(window, passphraseID, L"synthetic passphrase");
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
                const bool closed = !IsWindow(window);
                if (IsWindow(window)) DestroyWindow(window);
                Dialog cancelled;
                cancelled.config = snapshot();
                HWND second = createDialog(owner, cancelled);
                if (second) {
                    SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
                    if (IsWindow(second)) DestroyWindow(second);
                }
                passed = passphraseEnabled && closed && second && acted.calls == 1 && acted.action == applyAction &&
                    acted.history == 1 && acted.keys == 1 && acted.passphrase == "synthetic passphrase";
                if (!passed) error = "The iCloud sync dialog did not apply its choices exactly once.";
            }
        }
    } catch (const std::exception &) { error = "The iCloud sync self-test could not allocate its fixtures."; }
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
