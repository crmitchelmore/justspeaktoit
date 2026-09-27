#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

// Post-processing dialog: Off, Remote (OpenRouter) or Local (built-in rules or
// a downloaded language model on this PC). The prompt editor is shown for
// every model that follows it: remote models and local language models. The
// built-in rules never read a prompt, and the dialog says so in its place.
namespace {
enum SettingControl {
    enabledID = 300, modelID, promptID, keyID, warningID, modelLabelID, promptLabelID, keyLabelID, whereLabelID,
    promptNoteID
};
enum Mode { off = 0, remote = 1, local = 2 };

struct Configuration {
    std::vector<std::wstring> models;
    int selected = 0;
    bool enabled = false;
    std::vector<std::wstring> localModels;
    std::vector<bool> localUsesPrompt;
    int localSelected = 0;
    bool localEnabled = false;
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
    int mode = off;
    int remoteSelection = 0;
    int localSelection = 0;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), row = scale(window, 32);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int top, int height) { MoveWindow(GetDlgItem(window, id), margin, top, width, height, TRUE); };
    move(whereLabelID, margin, scale(window, 22));
    move(enabledID, margin + scale(window, 24), scale(window, 200));
    move(warningID, margin + scale(window, 24) + row + gap, scale(window, 42));
    move(modelLabelID, scale(window, 140), scale(window, 22));
    move(modelID, scale(window, 166), scale(window, 260));
    move(promptLabelID, scale(window, 212), scale(window, 22));
    move(promptNoteID, scale(window, 238), scale(window, 40));
    const int bottom = static_cast<int>(bounds.bottom);
    const int promptTop = scale(window, 284);
    const int promptHeight = std::max(scale(window, 80), bottom - scale(window, 452));
    move(promptID, promptTop, promptHeight);
    const int keyTop = promptTop + promptHeight + gap;
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

void show(HWND window, int id, bool visible) { ShowWindow(GetDlgItem(window, id), visible ? SW_SHOW : SW_HIDE); }

// Refills the model list for the chosen location and shows only the controls
// that apply to it.
void applyMode(HWND window, SettingsDialog &dialog) {
    const bool isLocal = dialog.mode == local, isRemote = dialog.mode == remote;
    HWND combo = GetDlgItem(window, modelID);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    const auto &names = isLocal ? dialog.config.localModels : dialog.config.models;
    if (isLocal || isRemote) {
        for (const auto &name : names) SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(isLocal ? dialog.localSelection : dialog.remoteSelection), 0);
    }
    const int chosen = dialog.localSelection;
    const bool followsPrompt = isRemote || (isLocal && chosen >= 0 &&
        static_cast<size_t>(chosen) < dialog.config.localUsesPrompt.size() && dialog.config.localUsesPrompt[chosen]);
    SetDlgItemTextW(window, warningID, isRemote
        ? L"Transcript text and your instructions are sent to OpenRouter. This step uses your account and may incur charges."
        : isLocal ? L"Runs on this PC: the transcript never leaves it. Download language models in Local models."
                  : L"Transcripts are kept exactly as transcribed.");
    SetDlgItemTextW(window, modelLabelID, isLocal ? L"Local post-processing &model" : L"Post-processing &model");
    SetDlgItemTextW(window, promptNoteID, !isLocal ? L""
        : followsPrompt ? L"This local model receives your instructions as its system prompt. Small models can ignore "
                          L"strict formatting instructions."
                        : L"Built-in rules cleanup ignores these instructions: it fixes spacing, capitalisation and "
                          L"punctuation with fixed rules on this PC.");
    show(window, modelLabelID, isLocal || isRemote);
    show(window, modelID, isLocal || isRemote);
    show(window, promptLabelID, followsPrompt);
    show(window, promptID, followsPrompt);
    show(window, promptNoteID, isLocal);
    show(window, keyLabelID, isRemote);
    show(window, keyID, isRemote);
}

bool createControls(HWND window, SettingsDialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
            GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay = add(L"STATIC", L"&Post-processing", 0, whereLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, enabledID) &&
        add(L"STATIC", L"", SS_LEFT, warningID) &&
        add(L"STATIC", L"Post-processing &model", 0, modelLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"STATIC", L"&Instructions for the model", 0, promptLabelID) &&
        add(L"STATIC", L"", SS_LEFT, promptNoteID) &&
        add(L"EDIT", dialog.config.prompt.c_str(), ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP, promptID) &&
        add(L"STATIC", L"New OpenRouter API &key (leave blank to keep the saved key)", 0, keyLabelID) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    const wchar_t *places[] = {L"Off", L"Remote — OpenRouter", L"Local — on this PC"};
    const int placeCount = dialog.config.localModels.empty() ? 2 : 3;
    for (int index = 0; index < placeCount; ++index) {
        const LRESULT added = SendDlgItemMessageW(window, enabledID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(places[index]));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
    }
    dialog.remoteSelection = dialog.config.selected;
    dialog.localSelection = dialog.config.localSelected;
    dialog.mode = dialog.config.localEnabled && !dialog.config.localModels.empty() ? local
        : dialog.config.enabled ? remote : off;
    SendDlgItemMessageW(window, enabledID, CB_SETCURSEL, static_cast<WPARAM>(dialog.mode), 0);
    SendDlgItemMessageW(window, promptID, EM_LIMITTEXT, 65535, 0);
    SendDlgItemMessageW(window, keyID, EM_LIMITTEXT, 2048, 0);
    refreshFont(window, dialog);
    applyMode(window, dialog);
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
    int selected = 0;
    if (dialog.mode != off) {
        const LRESULT chosen = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
        const size_t count = dialog.mode == local ? dialog.config.localModels.size() : dialog.config.models.size();
        if (chosen == CB_ERR || static_cast<size_t>(chosen) >= count) {
            SetDlgItemTextW(window, warningID, L"Choose a post-processing model before applying settings.");
            return;
        }
        selected = static_cast<int>(chosen);
    } else {
        selected = dialog.remoteSelection;
    }
    const std::string prompt = jsti::utf8(controlText(window, promptID));
    std::wstring secret = dialog.mode == remote ? controlText(window, keyID) : std::wstring();
    std::string key = jsti::utf8(secret);
    SetDlgItemTextW(window, keyID, L"");
    if (dialog.config.callback) {
        dialog.config.callback(dialog.mode, selected, prompt.c_str(), key.c_str(), dialog.config.context);
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
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 660), scale(window, 620)};
        return 0;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == enabledID && HIWORD(wparam) == CBN_SELCHANGE) {
            const LRESULT chosen = SendDlgItemMessageW(window, enabledID, CB_GETCURSEL, 0, 0);
            if (chosen >= off && chosen <= local) { dialog->mode = static_cast<int>(chosen); applyMode(window, *dialog); }
            return 0;
        }
        if (LOWORD(wparam) == modelID && HIWORD(wparam) == CBN_SELCHANGE) {
            const LRESULT chosen = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
            if (chosen != CB_ERR) {
                (dialog->mode == local ? dialog->localSelection : dialog->remoteSelection) = static_cast<int>(chosen);
                applyMode(window, *dialog);
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
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), scale(owner, 740), scale(owner, 680),
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
        {
            std::lock_guard<std::mutex> lock(configurationMutex);
            // The local list is configured separately and survives a remote update.
            updated.localModels = configuration.localModels;
            updated.localUsesPrompt = configuration.localUsesPrompt;
            updated.localSelected = configuration.localSelected;
            updated.localEnabled = configuration.localEnabled && !updated.enabled;
            configuration = std::move(updated);
        }
        // Configuration is intentionally valid before the main window exists.
        jsti_window_update(nullptr, nullptr, -1);
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_local_postprocessing(const char *const *names, const int *usesPrompt, size_t count,
                                         int selected, int enabled) {
    if (count > 1000 || (count && (!names || !usesPrompt)) || (enabled != 0 && enabled != 1) ||
        (count && (selected < 0 || static_cast<size_t>(selected) >= count)) || (enabled && !count)) return -1;
    try {
        std::vector<std::wstring> models(count);
        std::vector<bool> prompts(count);
        for (size_t i = 0; i < count; ++i) {
            if (!jsti::wide(names[i], models[i]) || models[i].empty() || (usesPrompt[i] != 0 && usesPrompt[i] != 1)) {
                return -1;
            }
            prompts[i] = usesPrompt[i] == 1;
        }
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.localModels = std::move(models);
        configuration.localUsesPrompt = std::move(prompts);
        configuration.localSelected = count ? selected : 0;
        configuration.localEnabled = enabled == 1;
        if (configuration.localEnabled) configuration.enabled = false;
        return 0;
    } catch (const std::exception &) { return -1; }
}

bool jsti_settings_self_test(HWND owner, std::string &error) {
    struct Applied { int calls = 0; bool matches = false; int mode = -1, selected = -1; std::string prompt, key; } applied;
    SettingsDialog dialog;
    dialog.config.models = {L"First model", L"Second model"};
    dialog.config.localModels = {L"Built-in rules", L"Local language model"};
    dialog.config.localUsesPrompt = {false, true};
    dialog.config.callback = [](int mode, int selected, const char *prompt, const char *key, void *context) {
        auto &result = *static_cast<Applied *>(context);
        result.calls++;
        result.mode = mode;
        result.selected = selected;
        result.prompt = prompt;
        result.key = key;
    };
    dialog.config.context = &applied;
    HWND window = createDialog(owner, dialog);
    if (!window) { error = jsti::systemError("Creating settings smoke-test window"); return false; }
    auto choose = [&](int id, int index) {
        SendDlgItemMessageW(window, id, CB_SETCURSEL, static_cast<WPARAM>(index), 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, CBN_SELCHANGE), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
    };
    // The fixture is never shown, so read each control's own visibility style.
    auto visible = [&](int id) { return (GetWindowLongPtrW(GetDlgItem(window, id), GWL_STYLE) & WS_VISIBLE) != 0; };
    // Off hides every model control; Remote shows the prompt and key.
    const bool offHidden = !visible(modelID) && !visible(promptID) && !visible(keyID);
    choose(enabledID, remote);
    const bool remoteShown = visible(modelID) && visible(promptID) && visible(keyID) && !visible(promptNoteID);
    // Local built-in rules: no prompt editor, and a note that the prompt is ignored.
    choose(enabledID, local);
    choose(modelID, 0);
    wchar_t note[256] = {};
    GetDlgItemTextW(window, promptNoteID, note, 256);
    const bool rulesExplained = !visible(promptID) && !visible(keyID) && visible(promptNoteID) &&
        std::wstring(note).find(L"ignores") != std::wstring::npos;
    // A local language model shows the prompt editor.
    choose(modelID, 1);
    const bool languageModelPrompt = visible(promptID) && !visible(keyID);
    SetDlgItemTextW(window, promptID, L"Keep café.\r\nDo not add words.");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    const bool localApplied = applied.calls == 1 && applied.mode == local && applied.selected == 1 &&
        applied.prompt == "Keep caf\xc3\xa9.\r\nDo not add words." && applied.key.empty();
    // Remote applies model, prompt and key in one atomic callback.
    SettingsDialog remoteDialog;
    remoteDialog.config = dialog.config;
    window = createDialog(owner, remoteDialog);
    if (!window) { error = jsti::systemError("Creating settings smoke-test window"); return false; }
    choose(enabledID, remote);
    choose(modelID, 1);
    SetDlgItemTextW(window, promptID, L"Keep café.\r\nDo not add words.");
    SetDlgItemTextW(window, keyID, L"synthetic-test-key");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    const bool remoteApplied = applied.calls == 2 && applied.mode == remote && applied.selected == 1 &&
        applied.prompt == "Keep caf\xc3\xa9.\r\nDo not add words." && applied.key == "synthetic-test-key";
    if (!offHidden || !remoteShown || !rulesExplained || !languageModelPrompt || !localApplied || !remoteApplied) {
        error = "Post-processing did not show the right controls per location or apply one atomic callback.";
        return false;
    }
    return true;
}
