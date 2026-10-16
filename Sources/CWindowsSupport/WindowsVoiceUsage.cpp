#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <cstring>
#include <objbase.h>
#include <vector>

int32_t jsti_save_owned_window_snapshot(HWND window, const char *path, char *error, size_t capacity);

namespace {
enum { reportLabelID = 980, reportID, trackingID };
constexpr UINT reportMessage = WM_APP + 27;
std::mutex usageMutex;
HWND active = nullptr;
std::string activeToken;
struct Report { std::string token; std::wstring text; bool tracking = true; };
Report pending;
struct Dialog {
    std::string token;
    JSTIVoiceSourceCallback callback = nullptr;
    void *context = nullptr;
    HFONT font = nullptr;
};
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), width = bounds.right - 2 * margin;
    MoveWindow(GetDlgItem(window, reportLabelID), margin, margin, width, scale(window, 24), TRUE);
    MoveWindow(GetDlgItem(window, reportID), margin, margin + scale(window, 30), width,
        bounds.bottom - 2 * margin - scale(window, 134), TRUE);
    MoveWindow(GetDlgItem(window, trackingID), margin, bounds.bottom - margin - scale(window, 94),
        width, scale(window, 44), TRUE);
    MoveWindow(GetDlgItem(window, IDCANCEL), bounds.right - margin - scale(window, 120),
        bounds.bottom - margin - scale(window, 34), scale(window, 120), scale(window, 34), TRUE);
}
void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    const int ids[] = {reportLabelID, reportID, trackingID, IDCANCEL};
    for (int id : ids)
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
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
        if (!add(L"STATIC", L"&Usage report (estimates, not charges)", 0, reportLabelID) ||
            !add(L"EDIT", L"Loading local usage... No synthesis request is sent.",
                ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, reportID, WS_EX_CLIENTEDGE) ||
            !add(L"BUTTON", L"&Keep local synthesis usage", BS_AUTOCHECKBOX | WS_TABSTOP, trackingID) ||
            !add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, IDCANCEL)) return -1;
        EnableWindow(GetDlgItem(window, trackingID), FALSE);
        font(window, *dialog); layout(window);
        std::lock_guard<std::mutex> lock(usageMutex);
        active = window; activeToken = dialog->token;
        return 0;
    }
    case reportMessage: {
        Report report;
        {
            std::lock_guard<std::mutex> lock(usageMutex);
            if (active != window || activeToken != dialog->token || pending.token != dialog->token) return 0;
            report = pending;
        }
        SetDlgItemTextW(window, reportID, report.text.c_str());
        SendDlgItemMessageW(window, trackingID, BM_SETCHECK, report.tracking ? BST_CHECKED : BST_UNCHECKED, 0);
        EnableWindow(GetDlgItem(window, trackingID), TRUE);
        return 0;
    }
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == trackingID && IsWindowEnabled(GetDlgItem(window, trackingID))) {
            const bool checked = SendDlgItemMessageW(window, trackingID, BM_GETCHECK, 0, 0) == BST_CHECKED;
            GUID identifier{}; wchar_t token[40]{};
            if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) {
                SendDlgItemMessageW(window, trackingID, BM_SETCHECK, checked ? BST_UNCHECKED : BST_CHECKED, 0);
                jsti_window_update("A Voice tracking request could not be created.", nullptr, -1); return 0;
            }
            dialog->token = jsti::utf8(token);
            { std::lock_guard<std::mutex> lock(usageMutex); activeToken = dialog->token; }
            EnableWindow(GetDlgItem(window, trackingID), FALSE);
            dialog->callback(118, checked ? 1 : 0, "", dialog->token.c_str(), "usage-tracking", dialog->context);
            return 0;
        }
        break;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 600), scale(window, 440)};
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
        {
            std::lock_guard<std::mutex> lock(usageMutex);
            if (active == window) { active = nullptr; activeToken.clear(); pending = {}; }
        }
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceUsage"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 660), scale(owner, 560)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Voice usage and input estimate",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}
}

int32_t jsti_window_set_voice_usage(const char *token, const char *text, int32_t tracking) {
    std::wstring value;
    if (!token || !token[0] || strlen(token) > 64 || !text || strlen(text) > 32768 ||
        (tracking != 0 && tracking != 1) || !jsti::wide(text, value)) return -1;
    std::lock_guard<std::mutex> lock(usageMutex);
    if (activeToken != token || !active) return 0;
    pending = {token, std::move(value), tracking == 1};
    return PostMessageW(active, reportMessage, 0, 0) ? 0 : -1;
}

void jsti_show_voice_usage(HWND owner, const std::string &snapshot, JSTIVoiceSourceCallback callback, void *context) {
    GUID identifier{}; wchar_t token[40]{};
    if (!callback || FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) {
        jsti_window_update("A Voice usage request could not be created.", nullptr, -1); return;
    }
    Dialog dialog{jsti::utf8(token), callback, context};
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The Voice usage report could not be opened.", nullptr, -1); return; }
    callback(118, -1, snapshot.c_str(), dialog.token.c_str(), "usage-report", context);
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, reportID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading Voice usage messages failed.", nullptr, -1);
}

bool jsti_voice_usage_self_test(HWND owner, std::string &error) {
    int calls = 0;
    Dialog dialog{"synthetic-usage-request", [](int32_t action, int32_t flag, const char *, const char *token,
        const char *path, void *context) {
        if (action == 118 && flag == 0 && std::string(token) != "synthetic-usage-request" &&
            std::string(path) == "usage-tracking") ++*static_cast<int *>(context);
    }, &calls};
    HWND window = makeDialog(owner, dialog);
    if (!window) { error = "Voice usage fixture could not open."; return false; }
    auto drain = [&] {
        MSG message{};
        while (PeekMessageW(&message, window, reportMessage, reportMessage, PM_REMOVE)) DispatchMessageW(&message);
    };
    bool passed = !IsWindowEnabled(GetDlgItem(window, trackingID)) &&
        jsti_window_set_voice_usage("obsolete", "Wrong report", 1) == 0;
    drain(); passed = passed && !IsWindowEnabled(GetDlgItem(window, trackingID));
    const char *fixture = "Synthetic fixture: no provider calls.\r\n\r\n"
        "Captured text: 100 input characters (Unicode scalars).\r\n"
        "Voice: Harper - MAI-Voice-2.1\r\nInput estimate: USD 0.0022.\r\n\r\n"
        "Estimates are not charges. No provider billing receipts or token counts are available.\r\n\r\n"
        "Local requests retained: 2 (latest 1000).\r\nValidated audio: 1 request; cancelled: 1.\r\n"
        "Validated audio: 1.25 seconds; 100 input characters.\r\n"
        "Known-price estimate: USD 0.0022. Unpriced requests excluded: 0.\r\n\r\n"
        "Transport attempts do not prove server receipt. Failed/cancelled requests may still be billed.\r\n"
        "Tracking on: only text-free local metadata is kept.";
    passed = jsti_window_set_voice_usage(dialog.token.c_str(), fixture, 1) == 0 && passed;
    drain(); passed = passed && IsWindowEnabled(GetDlgItem(window, trackingID));
    passed = jsti_window_set_voice_usage(dialog.token.c_str(), fixture, 1) == 0 && passed;
    SendDlgItemMessageW(window, trackingID, BM_CLICK, 0, 0);
    drain();
    passed = passed && calls == 1 && !IsWindowEnabled(GetDlgItem(window, trackingID));
    passed = jsti_window_set_voice_usage("synthetic-usage-request", fixture, 1) == 0 && passed;
    drain(); passed = passed && !IsWindowEnabled(GetDlgItem(window, trackingID));
    passed = jsti_window_set_voice_usage(dialog.token.c_str(), fixture, 1) == 0 && passed;
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
    RECT original{}; GetWindowRect(window, &original);
    MINMAXINFO minimum{}; SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y, SWP_NOMOVE | SWP_NOZORDER);
    passed = fits() && passed;
    SetWindowPos(window, nullptr, 0, 0, original.right - original.left, original.bottom - original.top,
        SWP_NOMOVE | SWP_NOZORDER);
    std::vector<wchar_t> path(32768, 0);
    const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", path.data(), static_cast<DWORD>(path.size()));
    if (length && length < path.size()) {
        char failure[1024]{}; ShowWindow(window, SW_SHOWNOACTIVATE);
        passed = jsti_save_owned_window_snapshot(window, (jsti::utf8(path.data()) + ".voice-usage.bmp").c_str(),
            failure, sizeof(failure)) == 0 && passed;
        if (failure[0]) error = failure;
    }
    DestroyWindow(window);
    passed = jsti_window_set_voice_usage(dialog.token.c_str(), fixture, 0) == 0 && passed;
    if (!passed && error.empty()) error = "Voice usage fixture failed bounds, opt-out acknowledgement or stale ownership.";
    return passed;
}
