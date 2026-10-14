#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <objbase.h>
#include <cstring>
#include <vector>

int32_t jsti_save_owned_window_snapshot(HWND window, const char *path, char *error, size_t capacity);

namespace {
enum { headingID = 990, voicesID, statusID, refreshID, chooseID, closeID };
constexpr UINT inventoryMessage = WM_APP + 28;
struct Inventory {
    std::string token;
    std::vector<std::wstring> labels;
    std::vector<std::string> identifiers;
    std::wstring status;
    int selected = -1;
    bool loading = false;
};
struct Dialog {
    std::string token;
    JSTIVoiceSourceCallback callback;
    void *context;
    HFONT font = nullptr;
    Inventory shown;
};
std::mutex mutex;
HWND active = nullptr;
std::string activeToken;
Inventory pending;
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
bool rows(const char *text, std::vector<std::string> &result) {
    if (!text || !text[0] || strlen(text) > 262144) return false;
    std::string value(text);
    size_t start = 0;
    do {
        const auto end = value.find('\n', start);
        auto row = value.substr(start, end == std::string::npos ? end : end - start);
        if (row.empty() || row.find('\r') != std::string::npos || result.size() >= 514) return false;
        result.push_back(std::move(row));
        if (end == std::string::npos) break;
        start = end + 1;
    } while (true);
    return true;
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), height = scale(window, 36);
    const int width = bounds.right - 2 * margin, bottom = bounds.bottom - margin - height;
    MoveWindow(GetDlgItem(window, headingID), margin, margin, width, scale(window, 44), TRUE);
    MoveWindow(GetDlgItem(window, voicesID), margin, margin + scale(window, 54), width,
        bottom - margin - scale(window, 180), TRUE);
    MoveWindow(GetDlgItem(window, statusID), margin, bottom - scale(window, 110), width, scale(window, 100), TRUE);
    MoveWindow(GetDlgItem(window, refreshID), margin, bottom, scale(window, 140), height, TRUE);
    MoveWindow(GetDlgItem(window, chooseID), bounds.right - margin - scale(window, 250) - gap,
        bottom, scale(window, 130), height, TRUE);
    MoveWindow(GetDlgItem(window, closeID), bounds.right - margin - scale(window, 120),
        bottom, scale(window, 120), height, TRUE);
}
void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    for (int id : {headingID, voicesID, statusID, refreshID, chooseID, closeID})
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
}
void sensitivity(HWND window, const Dialog &dialog) {
    const auto selected = SendDlgItemMessageW(window, voicesID, LB_GETCURSEL, 0, 0);
    EnableWindow(GetDlgItem(window, refreshID), !dialog.shown.loading);
    EnableWindow(GetDlgItem(window, voicesID), !dialog.shown.loading);
    EnableWindow(GetDlgItem(window, chooseID), !dialog.shown.loading && selected >= 0 &&
        static_cast<size_t>(selected) < dialog.shown.identifiers.size());
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id, DWORD extended = 0) {
            return CreateWindowExW(extended, type, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        if (!add(L"STATIC", L"&xAI voices: documented presets and explicitly refreshed account listing", 0, headingID) ||
            !add(L"LISTBOX", L"", LBS_NOTIFY | WS_VSCROLL | WS_HSCROLL | WS_TABSTOP, voicesID, WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"Preparing choices. No source text is sent.", 0, statusID) ||
            !add(L"BUTTON", L"&Refresh", BS_PUSHBUTTON | WS_TABSTOP, refreshID) ||
            !add(L"BUTTON", L"&Choose voice", BS_DEFPUSHBUTTON | WS_TABSTOP, chooseID) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, closeID)) return -1;
        EnableWindow(GetDlgItem(window, chooseID), FALSE);
        font(window, *dialog); layout(window);
        std::lock_guard<std::mutex> lock(mutex);
        active = window; activeToken = dialog->token;
        return 0;
    }
    case inventoryMessage: {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (active != window || activeToken != dialog->token || pending.token != dialog->token) return 0;
            dialog->shown = pending;
        }
        SendDlgItemMessageW(window, voicesID, LB_RESETCONTENT, 0, 0);
        for (const auto &label : dialog->shown.labels) {
            const auto result = SendDlgItemMessageW(window, voicesID, LB_ADDSTRING, 0,
                reinterpret_cast<LPARAM>(label.c_str()));
            if (result == LB_ERR || result == LB_ERRSPACE) {
                dialog->shown.identifiers.clear();
                SendDlgItemMessageW(window, voicesID, LB_RESETCONTENT, 0, 0);
                SetDlgItemTextW(window, statusID, L"The voice list could not be shown. Retry Refresh.");
                sensitivity(window, *dialog); return 0;
            }
        }
        SendDlgItemMessageW(window, voicesID, LB_SETCURSEL, dialog->shown.selected, 0);
        SetDlgItemTextW(window, statusID, dialog->shown.status.c_str());
        sensitivity(window, *dialog); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == voicesID && HIWORD(wparam) == LBN_SELCHANGE) {
            sensitivity(window, *dialog); return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == closeID || LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == refreshID && IsWindowEnabled(GetDlgItem(window, refreshID))) {
            dialog->shown.loading = true; sensitivity(window, *dialog);
            SetDlgItemTextW(window, statusID, L"Listing account voices. Close cancels.");
            dialog->callback(118, -1, "", dialog->token.c_str(), "account-refresh", dialog->context); return 0;
        }
        if (LOWORD(wparam) == chooseID && IsWindowEnabled(GetDlgItem(window, chooseID))) {
            const auto index = SendDlgItemMessageW(window, voicesID, LB_GETCURSEL, 0, 0);
            if (index >= 0 && static_cast<size_t>(index) < dialog->shown.identifiers.size())
                dialog->callback(118, -1, dialog->shown.identifiers[index].c_str(), dialog->token.c_str(),
                    "account-choose", dialog->context);
            return 0;
        }
        break;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 600), scale(window, 460)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        font(window, *dialog); layout(window); return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        { std::lock_guard<std::mutex> lock(mutex);
          if (active == window) { active = nullptr; activeToken.clear(); pending = {}; } }
        dialog->callback(118, -1, "", dialog->token.c_str(), "account-close", dialog->context);
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceDiscovery"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 660), scale(owner, 520)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"xAI account voices",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}
}

int32_t jsti_window_set_voice_account_inventory(const char *token, const char *labels, const char *identifiers,
                                               int32_t selected, const char *status, int32_t loading) {
    if (!token || !token[0] || strlen(token) > 64 || !status || strlen(status) > 4096 ||
        (loading != 0 && loading != 1)) return -1;
    Inventory inventory; inventory.token = token; inventory.selected = selected; inventory.loading = loading != 0;
    std::vector<std::string> names;
    if (!rows(labels, names) || !rows(identifiers, inventory.identifiers) ||
        names.size() != inventory.identifiers.size() || selected < -1 || selected >= static_cast<int>(names.size()) ||
        !jsti::wide(status, inventory.status)) return -1;
    for (size_t index = 0; index < names.size(); ++index) {
        std::wstring label;
        if (names[index].size() > 512 || !jsti::wide(names[index].c_str(), label) ||
            inventory.identifiers[index].size() > 260 || inventory.identifiers[index].rfind("xai/", 0) != 0)
            return -1;
        inventory.labels.push_back(std::move(label));
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || activeToken != token) return 0;
    pending = std::move(inventory);
    return PostMessageW(active, inventoryMessage, 0, 0) ? 0 : -1;
}

void jsti_show_voice_discovery(HWND owner, JSTIVoiceSourceCallback callback, void *context) {
    GUID identifier{}; wchar_t token[40]{};
    if (!callback || FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) {
        jsti_window_update("An account voice request could not be created.", nullptr, -1); return;
    }
    Dialog dialog{jsti::utf8(token), callback, context};
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The account voice chooser could not be opened.", nullptr, -1); return; }
    callback(118, -1, "", dialog.token.c_str(), "account-open", context);
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, voicesID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0)
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading account voice messages failed.", nullptr, -1);
}

bool jsti_voice_discovery_self_test(HWND owner, std::string &error) {
    struct Calls { std::string choice; int refreshed = 0, closed = 0; } calls;
    Dialog dialog{"synthetic-account-request", [](int32_t action, int32_t flag, const char *text,
        const char *, const char *path, void *context) {
        auto calls = static_cast<Calls *>(context);
        if (action != 118 || flag != -1) return;
        if (std::string(path) == "account-choose") calls->choice = text;
        if (std::string(path) == "account-refresh") ++calls->refreshed;
        if (std::string(path) == "account-close") ++calls->closed;
    }, &calls};
    HWND window = makeDialog(owner, dialog);
    if (!window) { error = "Account voice fixture could not open."; return false; }
    auto drain = [&] {
        MSG message{};
        while (PeekMessageW(&message, window, inventoryMessage, inventoryMessage, PM_REMOVE))
            DispatchMessageW(&message);
    };
    bool passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), "one", "xai/a\nxai/b", 0, "", 0) == -1;
    passed = jsti_window_set_voice_account_inventory("obsolete", "Wrong", "xai/wrong", 0, "", 0) == 0 && passed;
    drain(); passed = !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    const char *labels = "Eve - xAI Speech (documented preset)\nSynthetic account voice (account listing)";
    const char *ids = "xai/eve\nxai/Account-A";
    const char *status = "Synthetic fixture: no provider calls. Listing received: 1 additional account voice. "
        "Documented presets are labelled separately. Choose voice saves the stable identifier.";
    passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    drain(); SendDlgItemMessageW(window, chooseID, BM_CLICK, 0, 0);
    passed = calls.choice == "xai/Account-A" && passed;
    SendDlgItemMessageW(window, refreshID, BM_CLICK, 0, 0);
    passed = calls.refreshed == 1 && !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    passed = jsti_window_set_voice_account_inventory("obsolete", "Wrong", "xai/wrong", 0, "", 0) == 0 && passed;
    drain(); passed = !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    drain();
    auto fits = [&] {
        RECT client{}; GetClientRect(window, &client);
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom)
                return false;
        }
        return true;
    };
    passed = fits() && passed;
    MINMAXINFO minimum{}; SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y, SWP_NOMOVE | SWP_NOZORDER);
    passed = fits() && passed;
    std::vector<wchar_t> path(32768, 0);
    const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", path.data(), static_cast<DWORD>(path.size()));
    if (length && length < path.size()) {
        char failure[1024]{}; ShowWindow(window, SW_SHOWNOACTIVATE);
        passed = jsti_save_owned_window_snapshot(window, (jsti::utf8(path.data()) + ".voice-discovery.bmp").c_str(),
            failure, sizeof(failure)) == 0 && passed;
        if (failure[0]) error = failure;
    }
    DestroyWindow(window);
    passed = calls.closed == 1 &&
        jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    if (!passed && error.empty()) error = "Account voice fixture failed stable selection, loading, stale token or bounds.";
    return passed;
}
