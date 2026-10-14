#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <objbase.h>
#include <condition_variable>
#include <mutex>
#include <cstring>
#include <cctype>
#include <vector>

namespace {
std::mutex transitionMutex, registrationMutex;
std::condition_variable callbacksFinished;
JSTIVoiceProviderCredentialCallback providerCallback = nullptr;
void *providerContext = nullptr;
uint64_t registrationGeneration = 0;
size_t admittedCallbacks = 0;
bool closingRegistration = false;
thread_local size_t callbackDepth = 0;
}

uint64_t jsti_voice_provider_generation() {
    std::lock_guard<std::mutex> lock(registrationMutex);
    return providerCallback && !closingRegistration ? registrationGeneration : 0;
}
bool jsti_voice_provider_enter(uint64_t generation) {
    std::lock_guard<std::mutex> lock(registrationMutex);
    if (!generation || generation != registrationGeneration || !providerCallback || closingRegistration) return false;
    ++admittedCallbacks; ++callbackDepth;
    return true;
}
void jsti_voice_provider_leave() {
    std::lock_guard<std::mutex> lock(registrationMutex);
    --admittedCallbacks; --callbackDepth;
    if (!admittedCallbacks) callbacksFinished.notify_all();
}

namespace {
struct Admission {
    bool admitted;
    explicit Admission(uint64_t generation) : admitted(jsti_voice_provider_enter(generation)) {}
    ~Admission() { if (admitted) jsti_voice_provider_leave(); }
};
struct Form {
    uint64_t generation = 0;
    HWND window = nullptr;
    HFONT font = nullptr;
    std::string session, epoch, provider, viewID, writeID, writeSlot, operation, slot;
    std::wstring outcome;
    bool loading = false, saved = false, canSave = false;
};
struct Delivery {
    uint64_t generation = 0;
    std::string request, session, epoch, provider, slot;
    std::wstring label, privacy, status;
    int saved = -1;
    bool canSave = false, finish = false;
};
std::mutex formMutex;
HWND activeProviderForm = nullptr;
std::vector<Delivery> deliveries;
constexpr UINT providerDeliveryMessage = WM_APP + 28;
enum { labelID = 1030, privacyID, keyID, statusID, saveID, removeID, recheckID, closeID };
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
bool uuid(const char *value) {
    if (!value || strlen(value) != 36) return false;
    for (size_t index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != '-') return false;
        } else if (!isxdigit(static_cast<unsigned char>(value[index]))) return false;
    }
    return true;
}
bool sameUUID(const std::string &left, const std::string &right) {
    return uuid(left.c_str()) && uuid(right.c_str()) && _stricmp(left.c_str(), right.c_str()) == 0;
}
std::string newUUID() {
    GUID identifier{}; wchar_t text[40]{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, text, 40)) return {};
    return jsti::utf8(std::wstring(text + 1, 36));
}
void emit(Form &form, const char *operation, const std::string &request, const std::string &slot = "",
          const std::string &secret = "") {
    Admission admission(form.generation);
    if (!admission.admitted) return;
    JSTIVoiceProviderCredentialCallback callback;
    void *context;
    { std::lock_guard<std::mutex> lock(registrationMutex); callback = providerCallback; context = providerContext; }
    // Unregister clears the registry, but an admitted callback owns its old lease.
    if (!callback) return;
    callback(operation, "voice-output", form.provider.c_str(), slot.c_str(), form.session.c_str(),
        form.epoch.c_str(), request.c_str(), secret.c_str(), context);
}
void sensitivity(Form &form) {
    const bool live = form.generation == jsti_voice_provider_generation();
    const bool idle = live && !form.loading && form.writeID.empty();
    EnableWindow(GetDlgItem(form.window, keyID), idle && form.canSave);
    EnableWindow(GetDlgItem(form.window, saveID), idle && form.canSave && !form.slot.empty());
    EnableWindow(GetDlgItem(form.window, removeID), idle && form.canSave && form.saved && !form.slot.empty());
    EnableWindow(GetDlgItem(form.window, recheckID), live && form.writeID.empty() && !form.loading);
}
void requestView(Form &form) {
    form.viewID = newUUID(); form.slot.clear(); form.canSave = false; form.saved = false;
    SetDlgItemTextW(form.window, keyID, L"");
    form.loading = !form.viewID.empty();
    SetDlgItemTextW(form.window, statusID, form.loading ? L"Checking this account Voice key..."
        : L"A key request could not be created. Close and retry.");
    sensitivity(form);
    if (form.loading) emit(form, "open", form.viewID);
}
void cancel(Form &form) {
    if (!form.writeID.empty()) emit(form, "cancel", form.writeID);
    if (form.loading && !form.viewID.empty()) emit(form, "cancel", form.viewID);
    form.writeID.clear(); form.viewID.clear(); form.loading = false;
    SetDlgItemTextW(form.window, keyID, L"");
}
void save(Form &form, bool remove) {
    if (form.generation != jsti_voice_provider_generation() || form.loading || !form.writeID.empty() ||
        !form.canSave || form.slot.empty() || (remove && !form.saved)) return;
    if (remove && MessageBoxW(form.window, L"Remove the saved key for this account Voice provider?",
        L"Remove account Voice key", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES) return;
    const int count = GetWindowTextLengthW(GetDlgItem(form.window, keyID));
    std::vector<wchar_t> buffer(static_cast<size_t>(count) + 1);
    if (!remove) GetDlgItemTextW(form.window, keyID, buffer.data(), count + 1);
    std::string secret = remove ? "" : jsti::utf8(buffer.data());
    SecureZeroMemory(buffer.data(), buffer.size() * sizeof(wchar_t));
    SetDlgItemTextW(form.window, keyID, L"");
    if (!remove && (secret.empty() || secret.size() > 8192)) {
        if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
        SetDlgItemTextW(form.window, statusID, L"Enter a non-empty key of at most 8,192 UTF-8 bytes.");
        return;
    }
    form.writeID = newUUID();
    if (form.writeID.empty()) {
        if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
        SetDlgItemTextW(form.window, statusID, L"A key operation could not be created. Retry.");
        return;
    }
    form.writeSlot = form.slot; form.operation = remove ? "remove" : "replace";
    form.outcome.clear();
    sensitivity(form); SetDlgItemTextW(form.window, statusID, L"Updating this account Voice key...");
    emit(form, form.operation.c_str(), form.writeID, form.writeSlot, secret);
    if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
}
bool matches(const Form &form, const Delivery &delivery) {
    return delivery.generation == form.generation && delivery.generation == jsti_voice_provider_generation() &&
        sameUUID(form.session, delivery.session) && sameUUID(form.epoch, delivery.epoch) &&
        form.provider == delivery.provider;
}
void apply(Form &form, const Delivery &delivery) {
    if (!matches(form, delivery)) return;
    if (delivery.finish) {
        if (!sameUUID(form.writeID, delivery.request) || form.operation.empty() ||
            form.writeSlot.empty() || form.writeSlot != form.slot) return;
        form.writeID.clear(); form.writeSlot.clear(); form.operation.clear();
        form.outcome = delivery.status;
        requestView(form);
        SetDlgItemTextW(form.window, statusID, delivery.status.c_str());
        return;
    }
    if (!form.loading || !sameUUID(form.viewID, delivery.request) || !form.writeID.empty()) return;
    form.loading = false; form.slot = delivery.slot; form.saved = delivery.saved == 1;
    form.canSave = delivery.canSave && delivery.saved >= 0;
    SetDlgItemTextW(form.window, labelID, delivery.label.c_str());
    SetDlgItemTextW(form.window, privacyID, delivery.privacy.c_str());
    const std::wstring status = form.outcome.empty() ? delivery.status : form.outcome + L"\n" + delivery.status;
    SetDlgItemTextW(form.window, statusID, status.c_str());
    SetDlgItemTextW(form.window, keyID, L""); sensitivity(form);
}
void layout(HWND window) {
    RECT client{}; GetClientRect(window, &client);
    const int margin = scale(window, 20), width = client.right - 2 * margin, height = scale(window, 36);
    MoveWindow(GetDlgItem(window, labelID), margin, margin, width, scale(window, 44), TRUE);
    MoveWindow(GetDlgItem(window, privacyID), margin, scale(window, 74), width, scale(window, 88), TRUE);
    MoveWindow(GetDlgItem(window, keyID), margin, scale(window, 172), width, height, TRUE);
    const int bottom = client.bottom - margin - height;
    MoveWindow(GetDlgItem(window, statusID), margin, scale(window, 220), width, bottom - scale(window, 230), TRUE);
    const int buttonWidth = (width - 3 * scale(window, 10)) / 4;
    for (int index = 0; index < 4; ++index)
        MoveWindow(GetDlgItem(window, saveID + index), margin + index * (buttonWidth + scale(window, 10)),
            bottom, buttonWidth, height, TRUE);
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == providerDeliveryMessage) {
        std::vector<Delivery> values;
        { std::lock_guard<std::mutex> lock(formMutex); values.swap(deliveries); }
        for (const auto &value : values) {
            if (!value.generation || value.generation != jsti_voice_provider_generation()) continue;
            auto target = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
            if (target) apply(*target, value);
        }
        return 0;
    }
    auto form = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        form = static_cast<Form *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        form->window = window; SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(form));
    }
    if (!form) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *type, const wchar_t *label, DWORD style, int id, DWORD extended = 0) {
            return CreateWindowExW(extended, type, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        if (!add(L"STATIC", L"No key is displayed or prefilled. This form does not send source text.", 0, privacyID) ||
            !add(L"STATIC", L"Account Voice provider &key", 0, labelID) ||
            !add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID, WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"", 0, statusID) ||
            !add(L"BUTTON", L"&Replace key", BS_DEFPUSHBUTTON | WS_TABSTOP, saveID) ||
            !add(L"BUTTON", L"&Remove key", BS_PUSHBUTTON | WS_TABSTOP, removeID) ||
            !add(L"BUTTON", L"Re&check", BS_PUSHBUTTON | WS_TABSTOP, recheckID) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, closeID)) return -1;
        SendDlgItemMessageW(window, keyID, EM_SETLIMITTEXT, 8192, 0);
        form->font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL,
            FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        for (int id = labelID; id <= closeID; ++id)
            SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(form->font), TRUE);
        layout(window);
        { std::lock_guard<std::mutex> lock(formMutex); activeProviderForm = window; }
        return 0;
    }
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        switch (LOWORD(wparam)) {
        case IDOK: case saveID: save(*form, false); return 0;
        case removeID: save(*form, true); return 0;
        case recheckID:
            if (form->writeID.empty() && !form->loading) { form->outcome.clear(); requestView(*form); }
            return 0;
        case closeID: case IDCANCEL: DestroyWindow(window); return 0;
        }
        break;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        HFONT font = CreateFontW(-MulDiv(10, HIWORD(wparam), 72), 0, 0, 0, FW_NORMAL,
            FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        if (font) {
            for (int id = labelID; id <= closeID; ++id)
                SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            if (form->font) DeleteObject(form->font);
            form->font = font;
        }
        layout(window); return 0;
    }
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 620), scale(window, 480)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        cancel(*form);
        { std::lock_guard<std::mutex> lock(formMutex);
          if (activeProviderForm == window) { activeProviderForm = nullptr; deliveries.clear(); } }
        if (form->font) DeleteObject(form->font);
        form->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
bool bounded(const char *value, size_t maximum) { return value && strlen(value) <= maximum; }
int post(Delivery value) {
    if (!value.generation) return 0;
    std::lock_guard<std::mutex> lock(formMutex);
    if (!activeProviderForm) return 0;
    deliveries.push_back(std::move(value));
    if (PostMessageW(activeProviderForm, providerDeliveryMessage, 0, 0)) return 0;
    deliveries.pop_back(); return -1;
}
}

int32_t jsti_window_set_voice_provider_credential_handler(JSTIVoiceProviderCredentialCallback callback, void *context) {
    if ((callback == nullptr) != (context == nullptr) || callbackDepth) return -1;
    std::lock_guard<std::mutex> transition(transitionMutex);
    {
        std::unique_lock<std::mutex> lock(registrationMutex);
        // Keep the old callback/context until admitted guards have copied them.
        closingRegistration = true; ++registrationGeneration;
        callbacksFinished.wait(lock, [] { return admittedCallbacks == 0; });
        providerCallback = nullptr; providerContext = nullptr;
    }
    { std::lock_guard<std::mutex> lock(formMutex); deliveries.clear(); }
    { std::lock_guard<std::mutex> lock(registrationMutex);
      providerCallback = callback; providerContext = context; closingRegistration = false; }
    return 0;
}
int32_t jsti_window_set_voice_provider_credential(
    const char *request, const char *session, const char *epoch, const char *provider, const char *slot,
    const char *label, const char *privacy, const char *status, int32_t saved, int32_t canSave) {
    if (!uuid(request) || !uuid(session) || !uuid(epoch) || !bounded(provider, 32) || !provider[0] ||
        !bounded(slot, 128) || saved < -1 || saved > 1 || (canSave != 0 && canSave != 1) ||
        (saved >= 0 && !slot[0]) || (saved == -1 && (canSave || slot[0])) ||
        !bounded(label, 512) || !bounded(privacy, 4096) || !bounded(status, 2048)) return -1;
    Delivery value; value.generation = jsti_voice_provider_generation();
    value.request = request; value.session = session; value.epoch = epoch; value.provider = provider; value.slot = slot;
    value.saved = saved; value.canSave = canSave != 0;
    if (!jsti::wide(label, value.label) || !jsti::wide(privacy, value.privacy) || !jsti::wide(status, value.status)) return -1;
    return post(std::move(value));
}
int32_t jsti_window_finish_voice_provider_credential(
    const char *request, const char *session, const char *epoch, const char *provider, int32_t success,
    const char *message) {
    if (!uuid(request) || !uuid(session) || !uuid(epoch) || !bounded(provider, 32) || !provider[0] ||
        (success != 0 && success != 1) || !bounded(message, 2048)) return -1;
    Delivery value; value.generation = jsti_voice_provider_generation();
    value.request = request; value.session = session; value.epoch = epoch; value.provider = provider;
    value.finish = true;
    if (!jsti::wide(message, value.status)) return -1;
    return post(std::move(value));
}
void jsti_show_voice_provider_credentials(HWND owner, uint64_t generation,
    const std::string &session, const std::string &epoch, const std::string &provider) {
    if (!generation || generation != jsti_voice_provider_generation()) return;
    Form form; form.generation = generation; form.session = session; form.epoch = epoch; form.provider = provider;
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItAccountVoiceKey"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        jsti_window_update("The account Voice key form could not be registered.", nullptr, -1); return;
    }
    RECT size{0, 0, scale(owner, 640), scale(owner, 500)};
    AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    HWND window = CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Account Voice provider key",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, size.right - size.left, size.bottom - size.top,
        owner, nullptr, type.hInstance, &form);
    if (!window) { jsti_window_update("The account Voice key form could not be opened.", nullptr, -1); return; }
    requestView(form);
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, keyID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0)
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (!result) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading account Voice key messages failed.", nullptr, -1);
}
