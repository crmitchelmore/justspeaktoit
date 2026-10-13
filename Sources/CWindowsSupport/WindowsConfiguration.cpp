#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <mutex>
#include <vector>

namespace {
constexpr int fieldBase = 600, labelBase = 700, problemID = 800, importID = 801, exportID = 802;
struct Field { std::wstring title, value; bool boolean = false; };
struct Configuration {
    std::vector<Field> fields;
    JSTIConfigurationCallback callback = nullptr;
    void *context = nullptr;
};
Configuration configuration;
std::mutex configurationMutex;
struct Dialog { Configuration config; HFONT font = nullptr; std::vector<HWND> controls; };
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

std::wstring text(HWND window, int id) {
    HWND control = GetDlgItem(window, id);
    int length = GetWindowTextLengthW(control);
    std::wstring value(static_cast<size_t>(length) + 1, 0);
    value.resize(static_cast<size_t>(GetWindowTextW(control, value.data(), length + 1)));
    return value;
}

void layout(HWND window, Dialog &dialog) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    int y = scale(window, 16), margin = scale(window, 20), width = bounds.right - 2 * margin;
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const bool boolean = dialog.config.fields[i].boolean;
        if (!boolean) {
            MoveWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), margin, y, width, scale(window, 20), TRUE);
            y += scale(window, 22);
        }
        MoveWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), margin, y, width, scale(window, 28), TRUE);
        y += scale(window, boolean ? 34 : 38);
    }
    MoveWindow(GetDlgItem(window, problemID), margin, y, width, scale(window, 44), TRUE);
    const int bottom = bounds.bottom - scale(window, 48), button = scale(window, 100), gap = scale(window, 8);
    const int ids[] = {importID, exportID, IDOK, IDCANCEL};
    for (int i = 0; i < 4; ++i)
        MoveWindow(GetDlgItem(window, ids[i]), margin + i * (button + gap), bottom, button, scale(window, 32), TRUE);
}

bool controls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *title, DWORD style, int id) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, title,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control;
    };
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const auto &field = dialog.config.fields[i];
        HWND control;
        if (field.boolean) {
            control = add(L"BUTTON", field.title.c_str(), BS_AUTOCHECKBOX | WS_TABSTOP, fieldBase + static_cast<int>(i));
            if (control) SendMessageW(control, BM_SETCHECK, field.value == L"1" ? BST_CHECKED : BST_UNCHECKED, 0);
        } else {
            if (!add(L"STATIC", field.title.c_str(), SS_LEFT, labelBase + static_cast<int>(i))) return false;
            control = add(L"EDIT", field.value.c_str(), ES_AUTOHSCROLL | WS_TABSTOP, fieldBase + static_cast<int>(i));
            if (control) SendMessageW(control, EM_LIMITTEXT, 65535, 0);
        }
        if (!control) return false;
    }
    if (!add(L"STATIC", L"Import/export transfers portable preferences only, not keys or device settings.",
             SS_LEFT, problemID) ||
        !add(L"BUTTON", L"&Import...", BS_PUSHBUTTON | WS_TABSTOP, importID) ||
        !add(L"BUTTON", L"&Export...", BS_PUSHBUTTON | WS_TABSTOP, exportID) ||
        !add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) ||
        !add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL)) return false;
    dialog.font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (dialog.font)
        for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(dialog.font), TRUE);
    layout(window, dialog);
    return true;
}

void apply(HWND window, Dialog &dialog, int action) {
    std::vector<std::string> entries;
    if (action == 0) {
        for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
            entries.push_back(dialog.config.fields[i].boolean
                ? (SendDlgItemMessageW(window, fieldBase + static_cast<int>(i), BM_GETCHECK, 0, 0) == BST_CHECKED ? "1" : "0")
                : jsti::utf8(text(window, fieldBase + static_cast<int>(i))));
        }
    } else {
        wchar_t path[32768] = {};
        OPENFILENAMEW request{};
        request.lStructSize = sizeof(request);
        request.hwndOwner = window;
        request.lpstrFilter = L"Portable preferences (*.json)\0*.json\0\0";
        request.lpstrFile = path;
        request.nMaxFile = 32768;
        request.lpstrDefExt = L"json";
        request.Flags = OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
            (action == 1 ? OFN_FILEMUSTEXIST : OFN_OVERWRITEPROMPT);
        if (!(action == 1 ? GetOpenFileNameW(&request) : GetSaveFileNameW(&request))) {
            if (CommDlgExtendedError() != 0)
                SetDlgItemTextW(window, problemID, L"The configuration file dialog could not be opened.");
            return;
        }
        entries.push_back(jsti::utf8(path));
    }
    std::vector<const char *> borrowed;
    for (const auto &entry : entries) borrowed.push_back(entry.c_str());
    char error[1024] = {};
    if (dialog.config.callback(action, borrowed.data(), borrowed.size(), dialog.config.context, error, sizeof(error)) != 0) {
        std::wstring reason;
        if (!jsti::wide(error, reason) || reason.empty()) reason = L"Configuration could not be applied.";
        SetDlgItemTextW(window, problemID, reason.c_str());
        return;
    }
    DestroyWindow(window);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return controls(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window, *dialog); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        if (dialog->font)
            for (HWND control : dialog->controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(dialog->font), TRUE);
        layout(window, *dialog);
        return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 660), scale(window, 720)};
        return 0;
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog, 0); return 0; }
        if (LOWORD(wparam) == importID) { apply(window, *dialog, 1); return 0; }
        if (LOWORD(wparam) == exportID) { apply(window, *dialog, 2); return 0; }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        if (dialog->font) DeleteObject(dialog->font);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND createDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItConfiguration";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return nullptr;
    }
    return CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Dictation preferences - Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
        CW_USEDEFAULT, CW_USEDEFAULT, scale(owner, 700), scale(owner, 740), owner, nullptr, type.hInstance, &dialog);
}
} // namespace

void jsti_show_configuration(HWND owner) {
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(configurationMutex); dialog.config = configuration; }
    if (!dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening configuration editor").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, fieldBase));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading configuration messages").c_str(), nullptr, -1);
}

int jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
                                  JSTIConfigurationCallback callback, void *context) {
    if (!fields || !count || count > 32 || !callback) return -1;
    Configuration updated;
    try {
        for (size_t i = 0; i < count; ++i) {
            Field field;
            if (!jsti::wide(fields[i].title, field.title) || !jsti::wide(fields[i].value, field.value) ||
                field.value.size() > 65535 || (fields[i].is_boolean != 0 && fields[i].is_boolean != 1)) return -1;
            field.boolean = fields[i].is_boolean != 0;
            updated.fields.push_back(std::move(field));
        }
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
        return 0;
    } catch (const std::exception &) { return -1; }
}

void jsti_window_clear_configuration(void) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    configuration = Configuration();
}

bool jsti_configuration_self_test(HWND owner, std::string &error) {
    struct Applied { int calls = 0; bool correct = false; } applied;
    Dialog dialog;
    dialog.config.fields = {{L"Language", L"en_GB", false}, {L"HUD", L"1", true}};
    dialog.config.context = &applied;
    dialog.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                 char *error, size_t capacity) {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        if (action != 0 || count != 2 || std::string(values[0]) != "fr_FR") {
            return jsti::fail("Synthetic invalid language.", error, capacity);
        }
        result.correct = std::string(values[1]) == "0";
        return 0;
    };
    HWND window = createDialog(owner, dialog);
    if (!window) { error = "Could not create the configuration fixture."; return false; }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool refused = IsWindow(window) && applied.calls == 1 && text(window, problemID) == L"Synthetic invalid language.";
    SetDlgItemTextW(window, fieldBase, L"fr_FR");
    SendDlgItemMessageW(window, fieldBase + 1, BM_SETCHECK, BST_UNCHECKED, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool accepted = !IsWindow(window) && applied.calls == 2 && applied.correct;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog cancelled;
    cancelled.config = dialog.config;
    HWND second = createDialog(owner, cancelled);
    if (second) SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    const bool quiet = second && !IsWindow(second) && applied.calls == 2;
    if (!refused || !accepted || !quiet) {
        error = "Configuration editor did not validate, apply or cancel its native fields correctly.";
        return false;
    }
    return true;
}
