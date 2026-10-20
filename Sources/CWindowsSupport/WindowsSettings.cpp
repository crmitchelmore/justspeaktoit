#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

void jsti_show_local_cleanup(HWND owner);

namespace {
enum SettingControl {
    enabledID = 300, modelID, promptID, keyID, warningID, modelLabelID, promptLabelID, keyLabelID,
    locationLabelID, locationID, directivesID, tagsID, manageID, modeLabelID
};
struct Configuration {
    std::vector<std::wstring> models;
    int selected = 0;
    bool enabled = false;
    bool includeDirectives = true;
    bool includeTags = true;
    int localIndex = -1;
    int rememberedRemoteIndex = -1;
    std::wstring localNotice;
    std::wstring prompt;
    JSTIPostProcessingCallback callback = nullptr;
    void *context = nullptr;
    size_t remoteCount = SIZE_MAX;
};
std::mutex configurationMutex;
Configuration configuration;

struct SettingsDialog {
    Configuration config;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    int remoteSelected = -1;
    int localSelected = -1;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

size_t remoteBoundary(const Configuration &config) {
    return std::min(config.remoteCount == SIZE_MAX
        ? (config.localIndex >= 0 ? static_cast<size_t>(config.localIndex) : config.models.size())
        : config.remoteCount, config.models.size());
}

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), row = scale(window, 32);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int top, int height) { MoveWindow(GetDlgItem(window, id), margin, top, width, height, TRUE); };
    move(enabledID, margin, row);
    move(locationLabelID, scale(window, 58), scale(window, 22));
    move(locationID, scale(window, 84), scale(window, 180));
    move(modeLabelID, scale(window, 126), scale(window, 22));
    move(warningID, scale(window, 154), scale(window, 48));
    move(modelLabelID, scale(window, 210), scale(window, 22));
    move(modelID, scale(window, 236), scale(window, 260));
    move(manageID, scale(window, 274), row);
    move(directivesID, scale(window, 316), row);
    move(tagsID, scale(window, 356), row);
    move(promptLabelID, scale(window, 398), scale(window, 22));
    const int bottom = static_cast<int>(bounds.bottom);
    const int promptHeight = std::max(scale(window, 100), bottom - scale(window, 588));
    move(promptID, scale(window, 424), promptHeight);
    const int keyTop = scale(window, 424) + promptHeight + gap;
    move(keyLabelID, keyTop, scale(window, 22));
    move(keyID, keyTop + scale(window, 26), row);
    const int buttonWidth = scale(window, 100);
    MoveWindow(GetDlgItem(window, IDOK), static_cast<int>(bounds.right) - margin - 2 * buttonWidth - gap,
        bottom - margin - row, buttonWidth, row, TRUE);
    MoveWindow(GetDlgItem(window, IDCANCEL), static_cast<int>(bounds.right) - margin - buttonWidth,
        bottom - margin - row, buttonWidth, row, TRUE);
}

void updateModelControls(HWND window, const SettingsDialog &dialog) {
    const LRESULT location = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0);
    const bool local = location == 0;
    const LRESULT row = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    const LRESULT selected = row == CB_ERR ? CB_ERR : SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, row, 0);
    const bool available = selected >= 0 && static_cast<size_t>(selected) < dialog.config.models.size() &&
        (static_cast<size_t>(selected) >= remoteBoundary(dialog.config)) == local;
    const bool rules = available && selected == dialog.config.localIndex;
    const bool instructions = available && !rules && (local || location == 1);
    SetDlgItemTextW(window, modeLabelID, !available
        ? L"Mode: Select a supported model"
        : local ? L"Mode: Finished transcript (local, completed-only)"
        : L"Mode: Finished transcript (remote, optional streaming previews)");
    SetDlgItemTextW(window, warningID, location == CB_ERR
        ? L"The stored model is unavailable. Choose Local or Remote and a supported model before applying."
        : !available ? (local ? L"Choose a supported local model before applying."
        : L"The remembered remote model is unavailable. Choose a supported remote model before applying.")
        : rules ? dialog.config.localNotice.c_str()
        : local ? L"Downloaded GGUF models run privately in process. A pinned native runtime and verified model are required. No cloud or rules fallback."
        : L"When enabled, transcript text and your prompt are sent to OpenRouter. This step uses your account and may incur charges.");
    EnableWindow(GetDlgItem(window, modelID), location != CB_ERR);
    EnableWindow(GetDlgItem(window, promptID), instructions);
    EnableWindow(GetDlgItem(window, keyID), available && location == 1);
    EnableWindow(GetDlgItem(window, directivesID), instructions);
    EnableWindow(GetDlgItem(window, tagsID), instructions);
    ShowWindow(GetDlgItem(window, keyID), location == 1 ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(window, keyLabelID), location == 1 ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(window, manageID), local ? SW_SHOW : SW_HIDE);
    if (location != 1) SetDlgItemTextW(window, keyID, L"");
}

bool selectLocation(HWND window, SettingsDialog &dialog, int selected, bool chooseFirst) {
    const LRESULT location = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0);
    const bool local = location == 0;
    SendDlgItemMessageW(window, modelID, CB_RESETCONTENT, 0, 0);
    updateModelControls(window, dialog);
    if (location == CB_ERR) return true;
    int chosen = -1;
    for (size_t index = 0; index < dialog.config.models.size(); ++index) {
        if ((index >= remoteBoundary(dialog.config)) != local) continue;
        const LRESULT row = SendDlgItemMessageW(window, modelID, CB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(dialog.config.models[index].c_str()));
        if (row == CB_ERR || row == CB_ERRSPACE ||
            SendDlgItemMessageW(window, modelID, CB_SETITEMDATA, row, static_cast<LPARAM>(index)) == CB_ERR) return false;
        if (static_cast<int>(index) == selected || (chooseFirst && chosen < 0)) chosen = static_cast<int>(row);
    }
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, chosen, 0);
    if (chosen >= 0) {
        const int full = static_cast<int>(SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, chosen, 0));
        if (local) dialog.localSelected = full;
        else dialog.remoteSelected = full;
    }
    updateModelControls(window, dialog);
    return true;
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
    const bool okay = add(L"BUTTON", L"&Enable post-processing", BS_AUTOCHECKBOX | WS_TABSTOP, enabledID) &&
        add(L"STATIC", L"", SS_LEFT, warningID) &&
        add(L"STATIC", L"Model &source", 0, locationLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, locationID) &&
        add(L"STATIC", L"", 0, modeLabelID) &&
        add(L"STATIC", L"Post-processing &model", 0, modelLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"BUTTON", L"&Manage downloaded GGUF models...", BS_PUSHBUTTON | WS_TABSTOP, manageID) &&
        add(L"BUTTON", L"Include personal lexicon &directives", BS_AUTOCHECKBOX | WS_TABSTOP, directivesID) &&
        add(L"BUTTON", L"Include lexicon context &tags", BS_AUTOCHECKBOX | WS_TABSTOP, tagsID) &&
        add(L"STATIC", L"&Instructions for the model", 0, promptLabelID) &&
        add(L"EDIT", dialog.config.prompt.c_str(), ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP, promptID) &&
        add(L"STATIC", L"New OpenRouter API &key (leave blank to keep the saved key)", 0, keyLabelID) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    SendDlgItemMessageW(window, enabledID, BM_SETCHECK, dialog.config.enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    SendDlgItemMessageW(window, directivesID, BM_SETCHECK,
        dialog.config.includeDirectives ? BST_CHECKED : BST_UNCHECKED, 0);
    SendDlgItemMessageW(window, tagsID, BM_SETCHECK,
        dialog.config.includeTags ? BST_CHECKED : BST_UNCHECKED, 0);
    for (const auto *name : {L"Local", L"Remote"}) {
        const LRESULT row = SendDlgItemMessageW(window, locationID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name));
        if (row == CB_ERR || row == CB_ERRSPACE) return false;
    }
    const int selected = dialog.config.selected;
    const bool available = selected >= 0 && static_cast<size_t>(selected) < dialog.config.models.size();
    const size_t remote = remoteBoundary(dialog.config);
    dialog.remoteSelected = available && static_cast<size_t>(selected) < remote
        ? selected : dialog.config.rememberedRemoteIndex >= 0 &&
            static_cast<size_t>(dialog.config.rememberedRemoteIndex) < remote
        ? dialog.config.rememberedRemoteIndex : -1;
    dialog.localSelected = available && static_cast<size_t>(selected) >= remote ? selected : dialog.config.localIndex;
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL,
        available ? (static_cast<size_t>(selected) >= remote ? 0 : 1) : -1, 0);
    if (!selectLocation(window, dialog, selected, false)) return false;
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
    const LRESULT row = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    const LRESULT selected = row == CB_ERR ? CB_ERR : SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, row, 0);
    const LRESULT location = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0);
    if (selected < 0 || static_cast<size_t>(selected) >= dialog.config.models.size() ||
        (location != 0 && location != 1) ||
        ((static_cast<size_t>(selected) >= remoteBoundary(dialog.config)) != (location == 0))) {
        SetDlgItemTextW(window, warningID, L"Choose a post-processing model before applying settings.");
        return;
    }
    const std::string prompt = jsti::utf8(controlText(window, promptID));
    std::wstring secret = location == 1 ? controlText(window, keyID) : std::wstring();
    std::string key = jsti::utf8(secret);
    SetDlgItemTextW(window, keyID, L"");
    if (dialog.config.callback) {
        const int directives = SendDlgItemMessageW(window, directivesID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
        const int tags = SendDlgItemMessageW(window, tagsID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
        dialog.config.callback(enabled, static_cast<int>(selected), directives, tags,
            prompt.c_str(), key.c_str(), dialog.config.context);
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
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 660), scale(window, 710)};
        return 0;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == locationID && HIWORD(wparam) == CBN_SELCHANGE) {
            const bool local = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0) == 0;
            if (!selectLocation(window, *dialog, local ? dialog->localSelected : dialog->remoteSelected, false)) {
                SetDlgItemTextW(window, warningID, L"Models could not be displayed. Close and reopen these settings.");
                EnableWindow(GetDlgItem(window, IDOK), FALSE);
            }
            return 0;
        }
        if (LOWORD(wparam) == modelID && HIWORD(wparam) == CBN_SELCHANGE) {
            const LRESULT row = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
            const LRESULT selected = row == CB_ERR ? CB_ERR :
                SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, row, 0);
            if (selected >= 0 && static_cast<size_t>(selected) < dialog->config.models.size()) {
                if (static_cast<size_t>(selected) >= remoteBoundary(dialog->config))
                    dialog->localSelected = static_cast<int>(selected);
                else dialog->remoteSelected = static_cast<int>(selected);
            }
            updateModelControls(window, *dialog);
            return 0;
        }
        if (LOWORD(wparam) == manageID) {
            jsti_show_local_cleanup(window);
            { std::lock_guard<std::mutex> lock(configurationMutex);
              dialog->config.models = configuration.models;
              dialog->config.remoteCount = configuration.remoteCount;
              dialog->config.localIndex = configuration.localIndex;
              dialog->config.localNotice = configuration.localNotice;
              dialog->config.callback = configuration.callback;
              dialog->config.context = configuration.context; }
            const bool local = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0) == 0;
            if (!selectLocation(window, *dialog, local ? dialog->localSelected : dialog->remoteSelected, false)) {
                SetDlgItemTextW(window, warningID, L"Models could not be displayed. Close and reopen these settings.");
                EnableWindow(GetDlgItem(window, IDOK), FALSE);
            }
            return 0;
        }
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
        L"Post-processing — Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), scale(owner, 740), scale(owner, 760),
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
                                   int localIndex, int rememberedRemoteIndex, const char *localNotice,
                                   int includeDirectives, int includeTags,
                                   const char *prompt,
                                   JSTIPostProcessingCallback callback, void *context) {
    if (!names || !count || count > 10000 || !callback || selected < -1 ||
        (selected >= 0 && static_cast<size_t>(selected) >= count) ||
        localIndex < 0 || static_cast<size_t>(localIndex) >= count || !localNotice ||
        rememberedRemoteIndex < -1 || rememberedRemoteIndex >= localIndex ||
        (enabled != 0 && enabled != 1) || (includeDirectives != 0 && includeDirectives != 1) ||
        (includeTags != 0 && includeTags != 1)) return -1;
    try {
        Configuration updated;
        updated.models.resize(count);
        for (size_t i = 0; i < count; ++i) {
            if (!jsti::wide(names[i], updated.models[i])) return -1;
        }
        if (!jsti::wide(prompt ? prompt : "", updated.prompt) || updated.prompt.size() > 65535 ||
            !jsti::wide(localNotice, updated.localNotice) || updated.localNotice.empty()) return -1;
        updated.selected = selected;
        updated.enabled = enabled != 0;
        updated.includeDirectives = includeDirectives != 0;
        updated.includeTags = includeTags != 0;
        updated.localIndex = localIndex;
        updated.remoteCount = static_cast<size_t>(localIndex);
        updated.rememberedRemoteIndex = rememberedRemoteIndex;
        updated.callback = callback;
        updated.context = context;
        { std::lock_guard<std::mutex> lock(configurationMutex); configuration = std::move(updated); }
        // Configuration is intentionally valid before the main window exists.
        jsti_window_update(nullptr, nullptr, -1);
        return 0;
    } catch (const std::exception &) { return -1; }
}

int32_t jsti_window_set_cleanup_sources(size_t remoteCount) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    if (remoteCount > configuration.models.size() || configuration.localIndex < 0 ||
        remoteCount != static_cast<size_t>(configuration.localIndex)) return -1;
    configuration.remoteCount = remoteCount;
    return 0;
}

static bool localCleanupSourcesSelfTest(HWND owner, std::string &error) {
    struct Applied { int calls = 0; bool matches = false; } applied;
    SettingsDialog dialog;
    dialog.config.models = {L"Remote A", L"Remote B", L"Built-in rules", L"Local A", L"Local B"};
    dialog.config.remoteCount = 2; dialog.config.localIndex = 2;
    dialog.config.selected = 4; dialog.config.enabled = true;
    dialog.config.rememberedRemoteIndex = 1;
    dialog.config.includeDirectives = false; dialog.config.includeTags = true;
    dialog.config.localNotice = L"Built-in rules ignore custom instructions and context.";
    dialog.config.prompt = L"One stop after each word.\r\nExact second line.";
    dialog.config.callback = [](int enabled, int selected, int directives, int tags,
                                const char *prompt, const char *key, void *context) {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        result.matches = enabled == 1 && selected == 4 && directives == 0 && tags == 1
            && std::string(prompt) == "One stop after each word.\r\nExact second line." && std::string(key).empty();
    };
    dialog.config.context = &applied;
    HWND window = createDialog(owner, dialog);
    if (!window) { error = "Local cleanup settings test window could not be created."; return false; }
    bool okay = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0) == 0
        && SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0) == 2
        && SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, 2, 0) == 4
        && IsWindowEnabled(GetDlgItem(window, promptID)) && IsWindowEnabled(GetDlgItem(window, directivesID))
        && controlText(window, modeLabelID) == L"Mode: Finished transcript (local, completed-only)"
        && !(GetWindowLongPtrW(GetDlgItem(window, keyID), GWL_STYLE) & WS_VISIBLE)
        && (GetWindowLongPtrW(GetDlgItem(window, manageID), GWL_STYLE) & WS_VISIBLE);
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
    okay = okay && !IsWindowEnabled(GetDlgItem(window, promptID)) &&
        !IsWindowEnabled(GetDlgItem(window, directivesID)) && !IsWindowEnabled(GetDlgItem(window, tagsID)) &&
        controlText(window, modeLabelID) == L"Mode: Finished transcript (local, completed-only)" &&
        controlText(window, warningID) == dialog.config.localNotice;
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(modelID, CBN_SELCHANGE), 0);
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(locationID, CBN_SELCHANGE), 0);
    okay = okay && SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) == 2
        && SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0) == 1
        && controlText(window, modeLabelID) == L"Mode: Finished transcript (remote, optional streaming previews)"
        && SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, 1, 0) == 1;
    SetDlgItemTextW(window, keyID, L"must-not-reach-local-callback");
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(locationID, CBN_SELCHANGE), 0);
    okay = okay && SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0) == 2 &&
        IsWindowEnabled(GetDlgItem(window, promptID)) && controlText(window, keyID).empty();
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (!okay || applied.calls != 1 || !applied.matches) {
        error = "Local cleanup settings lost combined model index, exact prompt or source privacy controls."; return false;
    }
    dialog.controls.clear();
    dialog.config.rememberedRemoteIndex = -1;
    window = createDialog(owner, dialog);
    if (!window) { error = "Downloaded cleanup remote-recall fixture could not be created."; return false; }
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(locationID, CBN_SELCHANGE), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool noFallback = IsWindow(window) && applied.calls == 1 &&
        controlText(window, modeLabelID) == L"Mode: Select a supported model" &&
        SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0) == CB_ERR;
    if (IsWindow(window)) DestroyWindow(window);
    if (!noFallback || jsti_window_set_cleanup_sources(10001) != -1) {
        error = "Downloaded cleanup substituted an unavailable remote choice or accepted an invalid source boundary.";
        return false;
    }
    return true;
}

bool jsti_settings_self_test(HWND owner, std::string &error) {
    if (!localCleanupSourcesSelfTest(owner, error)) return false;
    struct Applied { int calls = 0; bool matches = false; } applied;
    SettingsDialog dialog;
    dialog.config.models = {L"First model", L"Second model", L"Local Cleanup (Offline)"};
    dialog.config.localIndex = 2;
    dialog.config.localNotice = L"Built-in rules ignore custom instructions. No API key is needed.";
    dialog.config.callback = [](int enabled, int selected, int directives, int tags,
                               const char *prompt, const char *key, void *context) {
        auto &result = *static_cast<Applied *>(context);
        result.calls++;
        result.matches = enabled == 1 && selected == 1 && std::string(prompt) == "Keep caf\xc3\xa9.\r\nDo not add words." &&
            std::string(key) == "synthetic-test-key" && directives == 0 && tags == 1;
    };
    dialog.config.context = &applied;
    HWND window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating settings smoke-test window"); return false; }
    SendDlgItemMessageW(window, enabledID, BM_SETCHECK, BST_CHECKED, 0);
    SendDlgItemMessageW(window, modelID, CB_SETCURSEL, 1, 0);
    SendDlgItemMessageW(window, directivesID, BM_SETCHECK, BST_UNCHECKED, 0);
    SetDlgItemTextW(window, promptID, L"Keep caf\u00e9.\r\nDo not add words.");
    SetDlgItemTextW(window, keyID, L"synthetic-test-key");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (applied.calls != 1 || !applied.matches) {
        error = "Settings did not apply enabled/model/prompt/key in one atomic callback.";
        return false;
    }
    applied = {};
    dialog.controls.clear();
    dialog.config.selected = dialog.config.localIndex;
    dialog.config.rememberedRemoteIndex = 1;
    dialog.config.prompt = L"Keep my remote instructions.";
    dialog.config.callback = [](int enabled, int selected, int directives, int tags,
                               const char *prompt, const char *key, void *context) {
        auto &result = *static_cast<Applied *>(context);
        result.calls++;
        result.matches = enabled == 1 && selected == 2 &&
            std::string(prompt) == "Keep my remote instructions." && std::string(key).empty() &&
            directives == 1 && tags == 1;
    };
    window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating local cleanup settings fixture"); return false; }
    const bool localControls = SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0) == 0 &&
        SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) == 1 &&
        !IsWindowEnabled(GetDlgItem(window, promptID)) && !IsWindowEnabled(GetDlgItem(window, keyID)) &&
        !IsWindowEnabled(GetDlgItem(window, directivesID)) && !IsWindowEnabled(GetDlgItem(window, tagsID)) &&
        controlText(window, directivesID) == L"Include personal lexicon &directives" &&
        controlText(window, tagsID) == L"Include lexicon context &tags" &&
        controlText(window, modeLabelID) == L"Mode: Finished transcript (local, completed-only)" &&
        controlText(window, warningID) == dialog.config.localNotice;
    SendDlgItemMessageW(window, enabledID, BM_SETCHECK, BST_CHECKED, 0);
    SetDlgItemTextW(window, keyID, L"must-not-reach-callback");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (!localControls || applied.calls != 1 || !applied.matches) {
        error = "Local cleanup controls or canonical callback selection leaked a remote key.";
        return false;
    }
    dialog.controls.clear();
    window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating remote recall fixture"); return false; }
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(locationID, CBN_SELCHANGE), 0);
    const LRESULT recalledRow = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    const bool recalled = recalledRow != CB_ERR &&
        SendDlgItemMessageW(window, modelID, CB_GETITEMDATA, recalledRow, 0) == 1;
    DestroyWindow(window);
    if (!recalled) { error = "Local reprojection lost the remembered nondefault remote model."; return false; }
    dialog.controls.clear();
    dialog.config.rememberedRemoteIndex = -1;
    window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating unavailable remote recall fixture"); return false; }
    SendDlgItemMessageW(window, locationID, CB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(locationID, CBN_SELCHANGE), 0);
    const int callsBeforeUnavailable = applied.calls;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool noSubstitute = IsWindow(window) && applied.calls == callsBeforeUnavailable &&
        SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0) == CB_ERR;
    DestroyWindow(window);
    if (!noSubstitute) { error = "Unavailable remembered remote model silently selected another route."; return false; }
    applied = {};
    dialog.controls.clear();
    dialog.config.selected = -1;
    window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating unavailable cleanup settings fixture"); return false; }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool refused = IsWindow(window) && applied.calls == 0 &&
        controlText(window, modeLabelID) == L"Mode: Select a supported model" &&
        SendDlgItemMessageW(window, locationID, CB_GETCURSEL, 0, 0) == CB_ERR &&
        SendDlgItemMessageW(window, modelID, CB_GETCOUNT, 0, 0) == 0 &&
        !IsWindowEnabled(GetDlgItem(window, keyID));
    if (IsWindow(window)) DestroyWindow(window);
    if (!refused) {
        error = "Unavailable post-processing selection was silently substituted or applied.";
        return false;
    }
    const char *names[] = {"Remote", "Local"};
    if (jsti_window_set_postprocessing(names, 2, 2, 0, 1, -1, "Offline", 1, 1, "",
                                      dialog.config.callback, &applied) != -1 ||
        jsti_window_set_postprocessing(names, 2, 1, 0, 2, -1, "Offline", 1, 1, "",
                                      dialog.config.callback, &applied) != -1 ||
        jsti_window_set_postprocessing(names, 2, 1, 0, 1, -1, "Offline", 2, 1, "",
                                      dialog.config.callback, &applied) != -1 ||
        jsti_window_set_postprocessing(names, 2, 1, 0, 1, 1, "Offline", 1, 1, "",
                                      dialog.config.callback, &applied) != -1) {
        error = "Post-processing accepted an invalid model/location/context switch.";
        return false;
    }
    return true;
}
