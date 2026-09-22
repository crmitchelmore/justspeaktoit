#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

namespace {
enum SettingControl { enabledID = 300, modelID, promptID, keyID, warningID, modelLabelID, promptLabelID, keyLabelID };
struct Configuration {
    std::vector<std::wstring> models;
    int selected = 0;
    bool enabled = false;
    std::wstring prompt;
    JSTIPostProcessingCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;

struct SettingsDialog {
    Configuration config;
    HFONT font = nullptr;
    std::vector<HWND> controls;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), row = scale(window, 32);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int top, int height) { MoveWindow(GetDlgItem(window, id), margin, top, width, height, TRUE); };
    move(enabledID, margin, row);
    move(warningID, margin + row + gap, scale(window, 42));
    move(modelLabelID, scale(window, 106), scale(window, 22));
    move(modelID, scale(window, 132), scale(window, 260));
    move(promptLabelID, scale(window, 178), scale(window, 22));
    const int bottom = static_cast<int>(bounds.bottom);
    const int promptHeight = std::max(scale(window, 100), bottom - scale(window, 372));
    move(promptID, scale(window, 204), promptHeight);
    const int keyTop = scale(window, 204) + promptHeight + gap;
    move(keyLabelID, keyTop, scale(window, 22));
    move(keyID, keyTop + scale(window, 26), row);
    const int buttonWidth = scale(window, 100);
    MoveWindow(GetDlgItem(window, IDOK), static_cast<int>(bounds.right) - margin - 2 * buttonWidth - gap,
        bottom - margin - row, buttonWidth, row, TRUE);
    MoveWindow(GetDlgItem(window, IDCANCEL), static_cast<int>(bounds.right) - margin - buttonWidth,
        bottom - margin - row, buttonWidth, row, TRUE);
}

void refreshFont(HWND window, SettingsDialog &dialog) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return;
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = font;
}

bool createControls(HWND window, SettingsDialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
            GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay = add(L"BUTTON", L"&Enable cloud post-processing with OpenRouter", BS_AUTOCHECKBOX | WS_TABSTOP, enabledID) &&
        add(L"STATIC", L"When enabled, transcript text and your prompt are sent to OpenRouter. This step uses your account and may incur charges.", SS_LEFT, warningID) &&
        add(L"STATIC", L"Post-processing &model", 0, modelLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"STATIC", L"&Instructions for the model", 0, promptLabelID) &&
        add(L"EDIT", dialog.config.prompt.c_str(), ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP, promptID) &&
        add(L"STATIC", L"New OpenRouter API &key (leave blank to keep the saved key)", 0, keyLabelID) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    SendDlgItemMessageW(window, enabledID, BM_SETCHECK, dialog.config.enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    for (const auto &name : dialog.config.models) {
        const LRESULT added = SendDlgItemMessageW(window, modelID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
    }
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, dialog.config.selected, 0);
    SendDlgItemMessageW(window, promptID, EM_LIMITTEXT, 65535, 0);
    SendDlgItemMessageW(window, keyID, EM_LIMITTEXT, 2048, 0);
    refreshFont(window, dialog);
    return true;
}

std::wstring controlText(HWND window, int id) {
    const HWND control = GetDlgItem(window, id);
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, 0);
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(copied));
    return text;
}

void apply(HWND window, SettingsDialog &dialog) {
    const int enabled = SendDlgItemMessageW(window, enabledID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
    const LRESULT selected = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    if (selected == CB_ERR || static_cast<size_t>(selected) >= dialog.config.models.size()) {
        SetDlgItemTextW(window, warningID, L"Choose a post-processing model before applying settings.");
        return;
    }
    const std::string prompt = jsti::utf8(controlText(window, promptID));
    std::wstring secret = controlText(window, keyID);
    std::string key = jsti::utf8(secret);
    SetDlgItemTextW(window, keyID, L"");
    if (dialog.config.callback) {
        dialog.config.callback(enabled, static_cast<int>(selected), prompt.c_str(), key.c_str(), dialog.config.context);
    }
    if (!secret.empty()) SecureZeroMemory(&secret[0], secret.size() * sizeof(wchar_t));
    if (!key.empty()) SecureZeroMemory(&key[0], key.size());
    DestroyWindow(window);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<SettingsDialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<SettingsDialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return createControls(window, *dialog) ? 0 : -1;
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 660), scale(window, 560)};
        return 0;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog); return 0; }
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND createDialog(HWND owner, SettingsDialog &dialog) {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItPostProcessing";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    return CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Cloud post-processing — Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), scale(owner, 740), scale(owner, 620),
        owner, nullptr, instance, &dialog);
}
}

bool jsti_postprocessing_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return !configuration.models.empty() && configuration.callback;
}

void jsti_show_postprocessing(HWND owner) {
    SettingsDialog dialog;
    { std::lock_guard<std::mutex> lock(configurationMutex); dialog.config = configuration; }
    if (dialog.config.models.empty() || !dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening post-processing settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, enabledID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading settings messages").c_str(), nullptr, -1);
}

int jsti_window_set_postprocessing(const char *const *names, size_t count, int selected, int enabled,
                                   const char *prompt, JSTIPostProcessingCallback callback, void *context) {
    if (!names || !count || count > 10000 || !callback || selected < 0 || static_cast<size_t>(selected) >= count ||
        (enabled != 0 && enabled != 1)) return -1;
    try {
        Configuration updated;
        updated.models.resize(count);
        for (size_t i = 0; i < count; ++i) {
            if (!jsti::wide(names[i], updated.models[i])) return -1;
        }
        if (!jsti::wide(prompt ? prompt : "", updated.prompt) || updated.prompt.size() > 65535) return -1;
        updated.selected = selected;
        updated.enabled = enabled != 0;
        updated.callback = callback;
        updated.context = context;
        { std::lock_guard<std::mutex> lock(configurationMutex); configuration = std::move(updated); }
        // Configuration is intentionally valid before the main window exists.
        jsti_window_update(nullptr, nullptr, -1);
        return 0;
    } catch (const std::exception &) { return -1; }
}

bool jsti_settings_self_test(HWND owner, std::string &error) {
    struct Applied { int calls = 0; bool matches = false; } applied;
    SettingsDialog dialog;
    dialog.config.models = {L"First model", L"Second model"};
    dialog.config.callback = [](int enabled, int selected, const char *prompt, const char *key, void *context) {
        auto &result = *static_cast<Applied *>(context);
        result.calls++;
        result.matches = enabled == 1 && selected == 1 && std::string(prompt) == "Keep caf\xc3\xa9.\r\nDo not add words." &&
            std::string(key) == "synthetic-test-key";
    };
    dialog.config.context = &applied;
    HWND window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating settings smoke-test window"); return false; }
    SendDlgItemMessageW(window, enabledID, BM_SETCHECK, BST_CHECKED, 0);
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 1, 0);
    SetDlgItemTextW(window, promptID, L"Keep caf\u00e9.\r\nDo not add words.");
    SetDlgItemTextW(window, keyID, L"synthetic-test-key");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (applied.calls != 1 || !applied.matches) {
        error = "Settings did not apply enabled/model/prompt/key in one atomic callback.";
        return false;
    }
    return true;
}
