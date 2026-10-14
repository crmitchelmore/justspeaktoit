#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <cmath>
#include <iomanip>
#include <locale>
#include <mutex>
#include <sstream>
#include <objbase.h>
#include <vector>

int32_t jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t capacity);

namespace {
enum { speedLabel = 960, speedID, pitchLabel, pitchID, ssmlID, noticeID, saveID, normalID };
struct Options { double speed = 1, pitch = 0; int ssml = 0, capabilities = 0; std::wstring voice = L"Deepgram"; };
std::mutex mutex;
Options saved;
HWND active = nullptr;
std::string activeRequest;
constexpr UINT completionMessage = WM_APP + 26;
struct Dialog {
    Options options;
    JSTIVoiceSourceCallback callback;
    void *context;
    HFONT font = nullptr;
    UINT dpi = 96;
    bool saving = false;
};
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
void fill(HWND window, const Options &options) {
    auto value = [](double number) {
        std::wostringstream stream; stream.imbue(std::locale::classic());
        stream << std::setprecision(17) << number; return stream.str();
    };
    SetDlgItemTextW(window, speedID, value(options.speed).c_str());
    SetDlgItemTextW(window, pitchID, value(options.pitch).c_str());
    SendDlgItemMessageW(window, ssmlID, BM_SETCHECK, options.ssml ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(GetDlgItem(window, speedID), options.capabilities & 1);
    EnableWindow(GetDlgItem(window, pitchID), options.capabilities & 2);
    EnableWindow(GetDlgItem(window, ssmlID), options.capabilities & 4);
}
bool number(HWND window, int id, double &value) {
    wchar_t text[64]{};
    GetDlgItemTextW(window, id, text, 64);
    std::wistringstream stream(text); stream.imbue(std::locale::classic());
    if (!(stream >> value)) return false;
    stream >> std::ws;
    return stream.eof() && std::isfinite(value);
}
bool save(HWND window, Dialog &dialog) {
    if (dialog.saving) return false;
    double speed = 0, pitch = 0;
    if (!number(window, speedID, speed) || !number(window, pitchID, pitch) ||
        speed < 0.5 || speed > 2 || pitch < -12 || pitch > 12 || std::round(pitch) != pitch) {
        SetDlgItemTextW(window, noticeID, L"Use speed 0.5 to 2 and a whole-number pitch -12 to 12 semitones.");
        return false;
    }
    const bool ssml = SendDlgItemMessageW(window, ssmlID, BM_GETCHECK, 0, 0) == BST_CHECKED;
    std::ostringstream json;
    json.imbue(std::locale::classic());
    json << std::setprecision(17) << "{\"speed\":" << speed << ",\"pitch\":" << pitch
         << ",\"useSSML\":" << (ssml ? "true" : "false") << "}";
    const std::string value = json.str();
    GUID identifier{};
    wchar_t token[40]{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) {
        SetDlgItemTextW(window, noticeID, L"A settings request could not be created."); return false;
    }
    const std::string request = jsti::utf8(token);
    { std::lock_guard<std::mutex> lock(mutex); activeRequest = request; }
    dialog.saving = true;
    EnableWindow(GetDlgItem(window, saveID), FALSE);
    EnableWindow(GetDlgItem(window, normalID), FALSE);
    EnableWindow(GetDlgItem(window, speedID), FALSE);
    EnableWindow(GetDlgItem(window, pitchID), FALSE);
    EnableWindow(GetDlgItem(window, ssmlID), FALSE);
    SetDlgItemTextW(window, noticeID, L"Saving synthesis controls...");
    dialog.callback(119, 0, value.c_str(), request.c_str(), "", dialog.context);
    return true;
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    if (message == WM_CREATE) {
        dialog->dpi = GetDpiForWindow(window);
        auto add = [&](const wchar_t *type, const wchar_t *label, DWORD style, int id,
                       int x, int y, int width, int height) {
            HWND child = CreateWindowExW(type == std::wstring(L"EDIT") ? WS_EX_CLIENTEDGE : 0,
                type, label, WS_CHILD | WS_VISIBLE | style, scale(window, x), scale(window, y),
                scale(window, width), scale(window, height), window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
            if (child) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(dialog->font), TRUE);
            return child != nullptr;
        };
        dialog->font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        if (!add(L"STATIC", dialog->options.voice.c_str(), SS_LEFT, 980, 20, 18, 450, 36) ||
            !add(L"STATIC", L"&Speed (0.5 to 2)", 0, speedLabel, 20, 65, 250, 24) ||
            !add(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, speedID, 300, 60, 150, 34) ||
            !add(L"STATIC", L"&Pitch (-12 to 12 semitones)", 0, pitchLabel, 20, 110, 270, 24) ||
            !add(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, pitchID, 300, 105, 150, 34) ||
            !add(L"BUTTON", L"Use &SSML", WS_TABSTOP | BS_AUTOCHECKBOX, ssmlID, 20, 150, 430, 34) ||
            !add(L"STATIC", L"Unsupported controls stay stored. Normal controls resets them explicitly. "
                L"Full SSML documents define their own prosody; use normal sliders or a fragment.", SS_LEFT,
                noticeID, 20, 195, 450, 76) ||
            !add(L"BUTTON", L"&Normal controls", WS_TABSTOP | BS_PUSHBUTTON, normalID, 20, 285, 150, 34) ||
            !add(L"BUTTON", L"&Save", WS_TABSTOP | BS_DEFPUSHBUTTON, saveID, 285, 285, 80, 34) ||
            !add(L"BUTTON", L"Cancel", WS_TABSTOP | BS_PUSHBUTTON, IDCANCEL, 375, 285, 95, 34)) return -1;
        fill(window, dialog->options);
        { std::lock_guard<std::mutex> lock(mutex); active = window; activeRequest.clear(); }
        return 0;
    }
    if (message == WM_DPICHANGED) {
        const UINT dpi = HIWORD(wparam), previous = dialog->dpi;
        HFONT font = CreateFontW(-MulDiv(10, dpi, 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            SetWindowPos(child, nullptr, MulDiv(bounds.left, dpi, previous), MulDiv(bounds.top, dpi, previous),
                MulDiv(bounds.right - bounds.left, dpi, previous), MulDiv(bounds.bottom - bounds.top, dpi, previous),
                SWP_NOZORDER | SWP_NOACTIVATE);
            if (font) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        }
        if (font) { DeleteObject(dialog->font); dialog->font = font; }
        dialog->dpi = dpi;
        RECT client{0, 0, MulDiv(490, dpi, 96), MulDiv(340, dpi, 96)};
        AdjustWindowRectExForDpi(&client, WS_CAPTION | WS_SYSMENU, FALSE,
            WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, dpi);
        const RECT &suggested = *reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, suggested.left, suggested.top,
            client.right - client.left, client.bottom - client.top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    if (message == completionMessage && dialog->saving) {
        if (wparam == 1) { DestroyWindow(window); return 0; }
        dialog->saving = false;
        EnableWindow(GetDlgItem(window, saveID), TRUE);
        EnableWindow(GetDlgItem(window, normalID), TRUE);
        EnableWindow(GetDlgItem(window, speedID), dialog->options.capabilities & 1);
        EnableWindow(GetDlgItem(window, pitchID), dialog->options.capabilities & 2);
        EnableWindow(GetDlgItem(window, ssmlID), dialog->options.capabilities & 4);
        SetDlgItemTextW(window, noticeID, L"Could not save controls. Previous settings are unchanged. Retry or Cancel.");
        return 0;
    }
    if (message == WM_COMMAND && HIWORD(wparam) == BN_CLICKED) {
        switch (LOWORD(wparam)) {
        case normalID: {
            Options normal = dialog->options; normal.speed = 1; normal.pitch = 0; normal.ssml = 0;
            fill(window, normal); return 0;
        }
        case saveID: save(window, *dialog); return 0;
        case IDCANCEL: DestroyWindow(window); return 0;
        }
    }
    if (message == WM_CLOSE) { DestroyWindow(window); return 0; }
    if (message == WM_DESTROY) {
        { std::lock_guard<std::mutex> lock(mutex); if (active == window) { active = nullptr; activeRequest.clear(); } }
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceControls"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 490), scale(owner, 340)};
    AdjustWindowRectExForDpi(&bounds, WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, type.lpszClassName, L"Voice synthesis controls",
        WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}
}

int32_t jsti_window_set_voice_synthesis_options(double speed, double pitch, int32_t ssml,
                                               int32_t capabilities, const char *voice) {
    std::wstring name;
    if (!std::isfinite(speed) || !std::isfinite(pitch) || ssml < 0 || ssml > 1 || capabilities < 0 || capabilities > 7 ||
        !jsti::wide(voice ? voice : "", name)) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    saved = {speed, pitch, ssml, capabilities, std::move(name)};
    return 0;
}
int32_t jsti_window_finish_voice_synthesis_options(const char *request, int32_t success) {
    if (!request || (success != 0 && success != 1)) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    if (activeRequest != request) return 0;
    return active && !PostMessageW(active, completionMessage, success, 0) ? -1 : 0;
}
void jsti_show_voice_controls(HWND owner, JSTIVoiceSourceCallback callback, void *context) {
    if (!callback) return;
    Dialog dialog{};
    { std::lock_guard<std::mutex> lock(mutex); dialog.options = saved; }
    dialog.callback = callback; dialog.context = context;
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The Voice synthesis controls could not be opened.", nullptr, -1); return; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, normalID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading Voice controls messages failed.", nullptr, -1);
}

bool jsti_voice_controls_self_test(HWND owner, std::string &error) {
        struct Receipt { int calls = 0; std::string json, request; } receipt;
        Dialog dialog{};
        dialog.options = {1.2345678901234567, -2, 1, 0, L"Synthetic compatible voice"};
        dialog.context = &receipt;
        dialog.callback = [](int32_t action, int32_t, const char *text, const char *request, const char *, void *context) {
            auto &result = *static_cast<Receipt *>(context);
            if (action == 119) { ++result.calls; result.json = text; result.request = request; }
        };
        HWND window = makeDialog(owner, dialog);
        if (!window) { error = "Voice controls fixture could not open."; return false; }
        double value = 0;
        bool passed = number(window, speedID, value) && value == dialog.options.speed &&
            !IsWindowEnabled(GetDlgItem(window, speedID)) && !IsWindowEnabled(GetDlgItem(window, pitchID)) &&
            !IsWindowEnabled(GetDlgItem(window, ssmlID));
        RECT client{}; GetClientRect(window, &client);
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            passed = passed && bounds.left >= 0 && bounds.top >= 0 &&
                bounds.right <= client.right && bounds.bottom <= client.bottom;
        }
        auto drain = [&] {
            MSG message{};
            while (IsWindow(window) && PeekMessageW(&message, window, completionMessage, completionMessage, PM_REMOVE))
                DispatchMessageW(&message);
        };
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(normalID, BN_CLICKED), 0);
        passed = save(window, dialog) && passed && receipt.json == "{\"speed\":1,\"pitch\":0,\"useSSML\":false}" &&
            !receipt.request.empty() && dialog.saving && !IsWindowEnabled(GetDlgItem(window, saveID));
        const std::string first = receipt.request;
        passed = jsti_window_finish_voice_synthesis_options("obsolete-request", 1) == 0 && passed;
        drain(); passed = passed && IsWindow(window) && dialog.saving;
        passed = jsti_window_finish_voice_synthesis_options(first.c_str(), 0) == 0 && passed;
        drain(); passed = passed && !dialog.saving && IsWindowEnabled(GetDlgItem(window, saveID));
        dialog.options.capabilities = 7; fill(window, dialog.options);
        SetDlgItemTextW(window, speedID, L"0.49");
        passed = !save(window, dialog) && receipt.calls == 1 && passed;
        fill(window, dialog.options);
        std::vector<wchar_t> path(32768, 0);
        const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", path.data(),
            static_cast<DWORD>(path.size()));
        if (length && length < path.size()) {
            char failure[1024]{}; ShowWindow(window, SW_SHOWNOACTIVATE);
            passed = jsti_owned_window_save_snapshot(window,
                (jsti::utf8(path.data()) + ".voice-controls.bmp").c_str(), failure, sizeof(failure)) == 0 && passed;
            if (failure[0]) error = failure;
        }
        passed = save(window, dialog) && passed && receipt.request != first;
        passed = jsti_window_finish_voice_synthesis_options(first.c_str(), 1) == 0 && passed;
        drain(); passed = passed && IsWindow(window) && dialog.saving;
        passed = jsti_window_finish_voice_synthesis_options(receipt.request.c_str(), 1) == 0 && passed;
        drain(); passed = passed && !IsWindow(window);
        if (IsWindow(window)) DestroyWindow(window);
        if (!passed && error.empty()) error = "Voice controls fixture failed bounds, capabilities, precision or save ownership.";
        return passed;
    }
