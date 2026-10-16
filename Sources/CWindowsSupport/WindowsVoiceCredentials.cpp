#include "include/CWindowsSupport.h"
#include "include/VoiceCredentials.h"
#include "WindowsSupportInternal.hpp"
#include <deque>
#include <cstring>
#include <mutex>
#include <objbase.h>
#include <stdexcept>
#include <vector>

namespace {
enum { titleID = 1030, privacyID, statusID, keyLabelID, keyID, saveID, removeID, closeID };
constexpr UINT deliveryMessage = WM_APP + 29;
constexpr DWORD style = WS_OVERLAPPEDWINDOW;
constexpr DWORD extended = WS_EX_CONTROLPARENT;
struct Handler { JSTIVoiceCredentialCallback callback = nullptr; void *context = nullptr; };
struct Delivery {
    enum Kind { view, finish, refresh } kind = view;
    std::string token, epoch, identifier;
    std::wstring label, privacy, status;
    int saved = -1;
    bool canSave = false, success = false;
};
struct Dialog {
    Handler handler;
    std::string viewToken, epoch, identifier, pendingToken, pendingEpoch;
    std::wstring outcome;
    bool ready = false, canSave = false, saved = false, loading = false;
    HFONT font = nullptr;
    HWND focus = nullptr;
};
std::mutex credentialMutex;
Handler handler;
HWND active = nullptr;
std::deque<Delivery> deliveries;

bool sameUUID(const std::string &first, const std::string &second) {
    return first.size() == 36 && second.size() == 36 && _stricmp(first.c_str(), second.c_str()) == 0;
}
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
std::string uuid() {
    GUID value{}; wchar_t text[40]{};
    if (FAILED(CoCreateGuid(&value)) || StringFromGUID2(value, text, 40) != 39) return {};
    return jsti::utf8(text).substr(1, 36);
}
void clearSecret(HWND window) {
    SetDlgItemTextW(window, keyID, L"");
    SendDlgItemMessageW(window, keyID, EM_EMPTYUNDOBUFFER, 0, 0);
}
void enable(HWND window, const Dialog &dialog) {
    const bool editable = dialog.ready && dialog.canSave && dialog.pendingToken.empty();
    EnableWindow(GetDlgItem(window, keyID), editable);
    EnableWindow(GetDlgItem(window, saveID), editable);
    EnableWindow(GetDlgItem(window, removeID), editable && dialog.saved);
    SetDlgItemTextW(window, closeID, dialog.pendingToken.empty() ? L"Close" : L"Cancel and close");
}
void requestView(HWND window, Dialog &dialog) {
    clearSecret(window);
    dialog.ready = false;
    dialog.loading = true;
    dialog.viewToken = uuid();
    enable(window, dialog);
    if (dialog.viewToken.empty()) {
        SetDlgItemTextW(window, statusID, L"A Voice key request could not be created. Close and retry.");
        return;
    }
    dialog.handler.callback("open", "voice-output", "", dialog.viewToken.c_str(), "", "", dialog.handler.context);
}
void cancel(Dialog &dialog) {
    if (!dialog.pendingToken.empty())
        dialog.handler.callback("cancel", "voice-output", "", dialog.pendingToken.c_str(), "", "", dialog.handler.context);
    if (dialog.loading && !dialog.viewToken.empty())
        dialog.handler.callback("cancel", "voice-output", "", dialog.viewToken.c_str(), "", "", dialog.handler.context);
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), width = bounds.right - 2 * margin;
    auto move = [&](int id, int y, int height) {
        MoveWindow(GetDlgItem(window, id), margin, scale(window, y), width, scale(window, height), TRUE);
    };
    move(titleID, 20, 46); move(privacyID, 76, 124); move(statusID, 210, 102);
    move(keyLabelID, 322, 24); move(keyID, 350, 34);
    const int top = bounds.bottom - margin - scale(window, 36), gap = scale(window, 10), button = scale(window, 140);
    MoveWindow(GetDlgItem(window, saveID), margin, top, button, scale(window, 36), TRUE);
    MoveWindow(GetDlgItem(window, removeID), margin + button + gap, top, button, scale(window, 36), TRUE);
    MoveWindow(GetDlgItem(window, closeID), bounds.right - margin - button, top, button, scale(window, 36), TRUE);
}
void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    for (int id = titleID; id <= closeID; ++id)
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
}
void submit(HWND window, Dialog &dialog, bool remove, bool confirmed = false) {
    if (!dialog.ready || !dialog.canSave || !dialog.pendingToken.empty() || (remove && !dialog.saved)) return;
    if (remove && !confirmed && MessageBoxW(window,
        L"Remove this saved provider key? Other features using the same key also lose access. "
        L"Cancel keeps the existing key.", L"Remove Voice provider key", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES)
        return;
    std::wstring key;
    std::string secret;
    try {
        if (!remove) {
            const int length = GetWindowTextLengthW(GetDlgItem(window, keyID));
            if (!length) {
                SetDlgItemTextW(window, statusID, L"Enter a new key. Blank input never removes the saved key.");
                return;
            }
            key.resize(static_cast<size_t>(length) + 1);
            GetDlgItemTextW(window, keyID, key.data(), length + 1);
            key.resize(static_cast<size_t>(length));
            secret = jsti::utf8(key);
        }
        const std::string token = uuid();
        if (token.empty()) throw std::runtime_error("request");
        dialog.pendingToken = token; dialog.pendingEpoch = dialog.epoch;
        clearSecret(window); enable(window, dialog);
        SetDlgItemTextW(window, statusID, remove ? L"Removing the provider key..." : L"Saving the provider key...");
        dialog.handler.callback(remove ? "remove" : "replace", "voice-output", dialog.identifier.c_str(),
            token.c_str(), dialog.pendingEpoch.c_str(), secret.c_str(), dialog.handler.context);
    } catch (const std::exception &) {
        SetDlgItemTextW(window, statusID, L"The key request could not be prepared. Close and retry.");
    }
    if (!key.empty()) SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
    if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
}
void deliver(HWND window, Dialog &dialog, const Delivery &value) {
    if (value.kind == Delivery::refresh) {
        cancel(dialog); requestView(window, dialog); return;
    }
    if (value.kind == Delivery::finish) {
        if (!sameUUID(value.token, dialog.pendingToken) || !sameUUID(value.epoch, dialog.pendingEpoch)) return;
        dialog.pendingToken.clear(); dialog.pendingEpoch.clear();
        dialog.outcome = value.status;
        SetDlgItemTextW(window, statusID, dialog.outcome.c_str());
        requestView(window, dialog);
        return;
    }
    if (!sameUUID(value.token, dialog.viewToken)) return;
    dialog.loading = false;
    if (!sameUUID(dialog.epoch, value.epoch)) clearSecret(window);
    dialog.epoch = value.epoch; dialog.identifier = value.identifier;
    dialog.ready = value.saved >= 0; dialog.saved = value.saved == 1; dialog.canSave = value.canSave;
    SetDlgItemTextW(window, titleID, value.label.c_str());
    SetDlgItemTextW(window, privacyID, value.privacy.c_str());
    const std::wstring status = dialog.outcome.empty() ? value.status : dialog.outcome + L"\r\n" + value.status;
    SetDlgItemTextW(window, statusID, status.c_str());
    enable(window, dialog);
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
        auto add = [&](const wchar_t *type, const wchar_t *text, DWORD flags, int id, DWORD extra = 0) {
            return CreateWindowExW(extra, type, text, WS_CHILD | WS_VISIBLE | flags, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        if (!add(L"STATIC", L"Voice provider key", 0, titleID) ||
            !add(L"STATIC", L"No key is shown or prefilled. No Voice text is sent by this form.", 0, privacyID) ||
            !add(L"STATIC", L"Checking the selected Voice provider key...", 0, statusID) ||
            !add(L"STATIC", L"&New API key (blank keeps the saved key)", 0, keyLabelID) ||
            !add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID, WS_EX_CLIENTEDGE) ||
            !add(L"BUTTON", L"&Save key", BS_DEFPUSHBUTTON | WS_TABSTOP, saveID) ||
            !add(L"BUTTON", L"&Remove saved key", BS_PUSHBUTTON | WS_TABSTOP, removeID) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, closeID)) return -1;
        SendDlgItemMessageW(window, keyID, EM_SETLIMITTEXT, 8193, 0);
        font(window, *dialog); layout(window); enable(window, *dialog);
        { std::lock_guard<std::mutex> lock(credentialMutex); active = window; deliveries.clear(); }
        return 0;
    }
    case deliveryMessage: {
        std::deque<Delivery> values;
        { std::lock_guard<std::mutex> lock(credentialMutex); values.swap(deliveries); }
        for (const auto &value : values) deliver(window, *dialog, value);
        return 0;
    }
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == saveID) submit(window, *dialog, false);
        else if (LOWORD(wparam) == removeID) submit(window, *dialog, true);
        else if (LOWORD(wparam) == closeID || LOWORD(wparam) == IDCANCEL) DestroyWindow(window);
        return 0;
    case DM_GETDEFID: return MAKELRESULT(saveID, DC_HASDEFID);
    case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) { dialog->focus = GetFocus(); return 0; }
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, keyID));
        return 0;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 540), scale(window, 460)};
        AdjustWindowRectExForDpi(&size, style, FALSE, extended, GetDpiForWindow(window));
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
        clearSecret(window); cancel(*dialog);
        { std::lock_guard<std::mutex> lock(credentialMutex);
          if (active == window) { active = nullptr; deliveries.clear(); } }
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceCredentials"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT size{0, 0, scale(owner, 620), scale(owner, 500)};
    AdjustWindowRectExForDpi(&size, style, FALSE, extended, GetDpiForWindow(owner));
    return CreateWindowExW(extended, type.lpszClassName, L"Voice provider key", style,
        CW_USEDEFAULT, CW_USEDEFAULT, size.right - size.left, size.bottom - size.top,
        owner, nullptr, type.hInstance, &dialog);
}
int post(Delivery value) {
    std::lock_guard<std::mutex> lock(credentialMutex);
    if (!active) return 0;
    deliveries.push_back(std::move(value));
    if (PostMessageW(active, deliveryMessage, 0, 0)) return 0;
    deliveries.pop_back(); return -1;
}
bool text(const char *value, size_t maximum, std::wstring &output) {
    return value && strlen(value) <= maximum && jsti::wide(value, output);
}
}

bool jsti_voice_credentials_available() {
    std::lock_guard<std::mutex> lock(credentialMutex); return handler.callback != nullptr;
}
int32_t jsti_window_set_voice_credential_handler(JSTIVoiceCredentialCallback callback, void *context) {
    if (!callback || !context) return -1;
    { std::lock_guard<std::mutex> lock(credentialMutex); handler = {callback, context}; }
    return 0;
}
void jsti_window_clear_voice_credentials() {
    std::lock_guard<std::mutex> lock(credentialMutex); handler = {};
}
void jsti_voice_credentials_selection_changed() {
    Delivery value; value.kind = Delivery::refresh;
    if (post(std::move(value)) < 0) jsti_window_update("The Voice key form could not be refreshed.", nullptr, -1);
}
int32_t jsti_window_set_voice_credential(const char *token, const char *epoch, const char *identifier,
    const char *label, const char *privacy, const char *status, int32_t saved, int32_t canSave) {
    if (!token || strlen(token) != 36 || !epoch || strlen(epoch) > 36 || !identifier || strlen(identifier) > 128 ||
        saved < -1 || saved > 1 || (canSave != 0 && canSave != 1) ||
        (saved >= 0 && (strlen(epoch) != 36 || !identifier[0])) || (saved == -1 && canSave)) return -1;
    Delivery value; value.token = token; value.epoch = epoch; value.identifier = identifier;
    value.saved = saved; value.canSave = canSave == 1;
    if (!text(label, 512, value.label) || !text(privacy, 4096, value.privacy) || !text(status, 2048, value.status)) return -1;
    return post(std::move(value));
}
int32_t jsti_window_finish_voice_credential(const char *token, const char *epoch, int32_t success, const char *message) {
    if (!token || strlen(token) != 36 || !epoch || strlen(epoch) != 36 || (success != 0 && success != 1)) return -1;
    Delivery value; value.kind = Delivery::finish; value.token = token; value.epoch = epoch; value.success = success == 1;
    if (!text(message, 2048, value.status)) return -1;
    return post(std::move(value));
}
void jsti_show_voice_credentials(HWND owner) {
    Dialog dialog;
    HWND existing = nullptr;
    { std::lock_guard<std::mutex> lock(credentialMutex);
      existing = active; dialog.handler = handler; }
    if (existing) { SetActiveWindow(existing); return; }
    if (!dialog.handler.callback) {
        jsti_window_update("Voice provider key entry is not configured.", nullptr, -1); return;
    }
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The Voice provider key form could not be opened.", nullptr, -1); return; }
    requestView(window, dialog);
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, keyID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading Voice provider key messages failed.", nullptr, -1);
}

bool jsti_voice_credentials_self_test(HWND owner, std::string &error) {
    struct Observed {
        int opens = 0, saves = 0, removes = 0, cancels = 0;
        bool valid = true;
        std::string token, epoch;
    } observed;
    Handler original;
    { std::lock_guard<std::mutex> lock(credentialMutex); original = handler; }
    auto callback = [](const char *operation, const char *purpose, const char *identifier,
        const char *token, const char *epoch, const char *secret, void *context) {
        auto &value = *static_cast<Observed *>(context);
        const std::string action(operation);
        value.valid = value.valid && std::string(purpose) == "voice-output" && strlen(token) == 36;
        if (action == "open") { ++value.opens; value.valid = value.valid && !identifier[0] && !epoch[0] && !secret[0]; }
        else if (action == "cancel") ++value.cancels;
        else {
            value.token = token; value.epoch = epoch;
            value.valid = value.valid && std::string(identifier) == "openai.tts.apiKey" && strlen(epoch) == 36;
            if (action == "replace") { ++value.saves; value.valid = value.valid && std::string(secret) == "synthetic-only"; }
            else if (action == "remove") { ++value.removes; value.valid = value.valid && !secret[0]; }
            else value.valid = false;
        }
    };
    bool passed = jsti_window_set_voice_credential_handler(nullptr, &observed) == -1 &&
        jsti_window_set_voice_credential_handler(callback, &observed) == 0;
    Dialog dialog; dialog.handler = {callback, &observed};
    HWND window = makeDialog(owner, dialog);
    if (!window) { error = "The native Voice key fixture could not open."; passed = false; }
    else {
        auto drain = [&] {
            MSG message{};
            while (PeekMessageW(&message, window, deliveryMessage, deliveryMessage, PM_REMOVE)) DispatchMessageW(&message);
        };
        auto present = [&](const std::string &token, const std::string &epoch) {
            passed = jsti_window_set_voice_credential(token.c_str(), epoch.c_str(), "openai.tts.apiKey",
                "OpenAI Voice Output key (separate from transcription)",
                "Synthetic fixture only. No vault access, provider calls or actual credentials.",
                "A synthetic saved key is present. It is not prefilled.", 1, 1) == 0 && passed;
            drain();
        };
        requestView(window, dialog);
        const std::string epoch = uuid(), previousView = dialog.viewToken;
        passed = passed && !IsWindowEnabled(GetDlgItem(window, keyID)) &&
            (GetWindowLongPtrW(GetDlgItem(window, keyID), GWL_STYLE) & ES_PASSWORD) != 0;
        present(uuid(), epoch);
        passed = passed && !IsWindowEnabled(GetDlgItem(window, keyID));
        present(dialog.viewToken, epoch);
        passed = passed && IsWindowEnabled(GetDlgItem(window, keyID)) &&
            GetWindowTextLengthW(GetDlgItem(window, keyID)) == 0;
        submit(window, dialog, false);
        passed = passed && observed.saves == 0 && dialog.pendingToken.empty();
        SetDlgItemTextW(window, keyID, L"synthetic-only"); submit(window, dialog, false);
        const std::string firstToken = dialog.pendingToken;
        passed = passed && observed.saves == 1 && GetWindowTextLengthW(GetDlgItem(window, keyID)) == 0 &&
            !IsWindowEnabled(GetDlgItem(window, keyID));
        passed = jsti_window_finish_voice_credential(firstToken.c_str(), uuid().c_str(), 1, "Wrong epoch") == 0 && passed;
        drain(); passed = passed && dialog.pendingToken == firstToken;
        passed = jsti_window_finish_voice_credential(firstToken.c_str(), epoch.c_str(), 0,
            "The save could not be confirmed. Check the credential store.") == 0 && passed;
        drain(); passed = passed && dialog.pendingToken.empty() && dialog.viewToken != previousView;
        present(dialog.viewToken, epoch);
        SetDlgItemTextW(window, keyID, L"synthetic-new-input");
        passed = jsti_window_finish_voice_credential(firstToken.c_str(), epoch.c_str(), 1, "Stale success") == 0 && passed;
        drain(); passed = passed && GetWindowTextLengthW(GetDlgItem(window, keyID)) == 19;
        jsti_voice_credentials_selection_changed(); drain();
        passed = passed && GetWindowTextLengthW(GetDlgItem(window, keyID)) == 0 && !dialog.ready;
        present(previousView, epoch); passed = passed && !dialog.ready;
        present(dialog.viewToken, uuid());
        submit(window, dialog, true, true);
        passed = passed && observed.removes == 1 && !dialog.pendingToken.empty();
        DestroyWindow(window);
        passed = passed && observed.valid && observed.opens >= 3 && observed.cancels == 1;
        const int before = observed.opens;
        passed = jsti_window_finish_voice_credential(observed.token.c_str(), observed.epoch.c_str(), 1,
            "Closed form completion") == 0 && observed.opens == before && passed;
    }
    { std::lock_guard<std::mutex> lock(credentialMutex); handler = original; }
    if (!passed && error.empty())
        error = "Voice key masking, explicit removal, snapshot fencing, cancellation or late-completion protection failed.";
    return passed;
}
