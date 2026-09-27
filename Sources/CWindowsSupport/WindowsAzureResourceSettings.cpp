#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

// Native Azure Speech resource dialog: the HTTPS endpoint Azure live
// transcription connects to. The host validates each Apply synchronously with
// its canonical rule; while it refuses an entry the dialog stays open and
// shows the host's reason. Credentials never pass through this dialog.

namespace {
enum Control { introID = 1000, endpointLabelID, endpointID, noteID, problemID };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 330;
constexpr size_t maximumEndpointLength = 2048;

struct Configuration {
    std::wstring endpoint;
    JSTIAzureResourceCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;

struct Dialog {
    Configuration config;
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
    const int margin = at(20), button = at(32), gap = at(10), buttonWidth = at(100);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, at(16), width, at(44));
    move(endpointLabelID, margin, at(66), width, at(22));
    move(endpointID, margin, at(90), width, at(28));
    move(problemID, margin, at(124), width, at(40));
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    move(noteID, margin, at(168), width, std::max(at(44), top - gap - at(168)));
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
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
            GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Azure live transcription connects to your own Azure Speech or Foundry resource. "
            L"Paste the HTTPS endpoint from the resource’s Keys and Endpoint page.", SS_LEFT, introID) &&
        add(L"STATIC", L"Resource &endpoint", 0, endpointLabelID) &&
        add(L"EDIT", dialog.config.endpoint.c_str(), ES_AUTOHSCROLL | WS_TABSTOP, endpointID) &&
        add(L"STATIC", L"", SS_LEFT, problemID) &&
        add(L"STATIC", L"For example https://your-resource.services.ai.azure.com. The key stays in Windows "
            L"Credential Manager as key:region. Recorded audio also uses this endpoint, or your region when it "
            L"is empty. Available models depend on the resource’s region and tier.", SS_LEFT, noteID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    SendDlgItemMessageW(window, endpointID, EM_LIMITTEXT, maximumEndpointLength, 0);
    refreshFont(window, dialog);
    layout(window);
    return true;
}

std::wstring controlText(HWND window, int id) {
    const HWND control = GetDlgItem(window, id);
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, 0);
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

/// One Apply: the host accepts the entry and the dialog closes, or refuses it
/// and the dialog stays open with the host's reason.
void apply(HWND window, Dialog &dialog) {
    if (dialog.applied || !dialog.config.callback) return;
    const std::wstring entry = controlText(window, endpointID);
    const std::string endpoint = jsti::utf8(entry);
    if (!entry.empty() && endpoint.empty()) {
        SetDlgItemTextW(window, problemID, L"The endpoint contains characters that cannot be saved.");
        return;
    }
    char problem[512] = {};
    if (dialog.config.callback(endpoint.c_str(), dialog.config.context, problem, sizeof(problem)) != 0) {
        std::wstring reason;
        if (!problem[0] || !jsti::wide(problem, reason) || reason.empty()) reason = L"This endpoint cannot be used.";
        SetDlgItemTextW(window, problemID, reason.c_str());
        SetFocus(GetDlgItem(window, endpointID));
        SendDlgItemMessageW(window, endpointID, EM_SETSEL, 0, -1);
        return;
    }
    dialog.applied = true;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.endpoint = entry;
    }
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
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, endpointID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
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
    type.lpszClassName = L"JustSpeakToItAzureResource";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 600), scale(owner, 350)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Azure Speech resource — Just Speak to It",
        windowStyle, bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}
} // namespace

bool jsti_azure_resource_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr;
}

void jsti_show_azure_resource_settings(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening Azure Speech resource settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, endpointID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading Azure Speech resource messages").c_str(), nullptr, -1);
}

int jsti_window_set_azure_resource(const char *endpoint, JSTIAzureResourceCallback callback, void *context) {
    if (!callback || !endpoint) return -1;
    try {
        Configuration updated;
        if (!jsti::wide(endpoint, updated.endpoint) || updated.endpoint.size() > maximumEndpointLength) return -1;
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_azure_resource(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
constexpr char refusedEndpoint[] = "https://refused.example";
constexpr char refusalReason[] = "Synthetic refusal \xe2\x80\x94 use the resource endpoint.";
struct Applied { int calls = 0; std::string endpoint; };
int recordEndpoint(const char *endpoint, void *context, char *error, size_t capacity) {
    auto &applied = *static_cast<Applied *>(context);
    ++applied.calls;
    applied.endpoint = endpoint ? endpoint : "";
    if (applied.endpoint != refusedEndpoint) return 0;
    return jsti::fail(refusalReason, error, capacity);
}
} // namespace

// Configuration validation, a refused Apply that keeps the dialog open with the
// host's reason, an accepted Apply that closes it and is shown when reopened,
// and Cancel emitting nothing.
bool jsti_azure_resource_settings_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Applied applied;
    bool passed = false;
    try {
        const std::string tooLong(maximumEndpointLength + 1, 'a');
        const char *saved = "https://saved.services.ai.azure.com";
        const char *accepted = "https://synthetic.cognitiveservices.azure.com";
        if (jsti_window_set_azure_resource(saved, nullptr, &applied) != -1 ||
            jsti_window_set_azure_resource(tooLong.c_str(), recordEndpoint, &applied) != -1 ||
            jsti_window_set_azure_resource(saved, recordEndpoint, &applied) != 0 || !jsti_azure_resource_available()) {
            error = "Azure resource configuration accepted an invalid entry or rejected a valid one.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the Azure resource fixture");
            } else {
                std::wstring expectedSaved;
                const bool shown = jsti::wide(saved, expectedSaved) && controlText(window, endpointID) == expectedSaved;
                SetDlgItemTextW(window, endpointID, L"https://refused.example");
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
                std::wstring reason;
                const bool refused = IsWindow(window) && applied.calls == 1 && jsti::wide(refusalReason, reason) &&
                    controlText(window, problemID) == reason;
                std::wstring acceptedText;
                jsti::wide(accepted, acceptedText);
                if (IsWindow(window)) {
                    SetDlgItemTextW(window, endpointID, acceptedText.c_str());
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
                }
                const bool closed = !IsWindow(window) && applied.calls == 2 && applied.endpoint == accepted;
                if (IsWindow(window)) DestroyWindow(window);
                Dialog reopened;
                reopened.config = snapshot();
                HWND second = createDialog(owner, reopened);
                const bool remembered = second && controlText(second, endpointID) == acceptedText;
                if (second) {
                    SetDlgItemTextW(second, endpointID, L"https://discarded.services.ai.azure.com");
                    SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
                    if (IsWindow(second)) DestroyWindow(second);
                }
                passed = shown && refused && closed && remembered && applied.calls == 2;
                if (!passed) {
                    error = "The Azure resource dialog did not show, refuse, apply or cancel its endpoint as expected.";
                }
            }
        }
    } catch (const std::exception &) { error = "The Azure resource self-test could not allocate its fixtures."; }
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
