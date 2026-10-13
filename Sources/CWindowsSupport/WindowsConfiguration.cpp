#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <algorithm>
#include <commdlg.h>
#include <mutex>
#include <sstream>
#include <vector>

namespace {
constexpr int groupLabelID = 598, groupID = 599, fieldBase = 600, labelBase = 700;
constexpr int problemID = 800, importID = 801, exportID = 802;
constexpr int recoveryLabelID = 803, recoveryID = 804, restoreID = 805;
constexpr int previewStartID = 806, previewStopID = 807;
struct Field {
    std::wstring title, value, group;
    bool boolean = false;
    std::vector<std::pair<std::wstring, std::wstring>> choices;
};
struct Configuration {
    std::vector<Field> fields;
    std::vector<std::wstring> recovered;
    JSTIConfigurationCallback callback = nullptr;
    void *context = nullptr;
};
Configuration configuration;
std::mutex configurationMutex;
struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    std::vector<std::wstring> groups;
    std::wstring group = L"General";
};
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
    int y = scale(window, 62), margin = scale(window, 20), width = bounds.right - 2 * margin;
    MoveWindow(GetDlgItem(window, groupLabelID), margin, scale(window, 20), scale(window, 90), scale(window, 24), TRUE);
    MoveWindow(GetDlgItem(window, groupID), margin + scale(window, 90), scale(window, 16),
        width - scale(window, 90), scale(window, 200), TRUE);
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const bool visible = dialog.config.fields[i].group == dialog.group;
        ShowWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), visible ? SW_SHOW : SW_HIDE);
        ShowWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), visible ? SW_SHOW : SW_HIDE);
        if (!visible) continue;
        const bool boolean = dialog.config.fields[i].boolean;
        if (!boolean) {
            MoveWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), margin, y, width, scale(window, 20), TRUE);
            y += scale(window, 22);
        }
        MoveWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), margin, y, width,
            scale(window, dialog.config.fields[i].choices.empty() ? 28 : 200), TRUE);
        y += scale(window, boolean ? 34 : 38);
    }
    const bool recovery = dialog.group == L"Transcription" && !dialog.config.recovered.empty();
    const bool sounds = dialog.group == L"General";
    for (int id : {previewStartID, previewStopID}) ShowWindow(GetDlgItem(window, id), sounds ? SW_SHOW : SW_HIDE);
    if (sounds) {
        const int half = (width - scale(window, 8)) / 2;
        MoveWindow(GetDlgItem(window, previewStartID), margin, y, half, scale(window, 32), TRUE);
        MoveWindow(GetDlgItem(window, previewStopID), margin + half + scale(window, 8), y, half, scale(window, 32), TRUE);
        y += scale(window, 44);
    }
    for (int id : {recoveryLabelID, recoveryID, restoreID})
        ShowWindow(GetDlgItem(window, id), recovery ? SW_SHOW : SW_HIDE);
    if (recovery) {
        MoveWindow(GetDlgItem(window, recoveryLabelID), margin, y, width, scale(window, 20), TRUE);
        y += scale(window, 24);
        MoveWindow(GetDlgItem(window, recoveryID), margin, y, width, scale(window, 200), TRUE);
        y += scale(window, 36);
        MoveWindow(GetDlgItem(window, restoreID), margin, y, scale(window, 220), scale(window, 32), TRUE);
        y += scale(window, 40);
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
    if (!add(L"STATIC", L"&Section:", SS_LEFT, groupLabelID) ||
        !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, groupID)) return false;
    for (const auto &field : dialog.config.fields)
        if (std::find(dialog.groups.begin(), dialog.groups.end(), field.group) == dialog.groups.end())
            dialog.groups.push_back(field.group);
    int selected = 0;
    for (size_t i = 0; i < dialog.groups.size(); ++i) {
        if (SendDlgItemMessageW(window, groupID, CB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(dialog.groups[i].c_str())) < 0) return false;
        if (dialog.groups[i] == dialog.group) selected = static_cast<int>(i);
    }
    dialog.group = dialog.groups[static_cast<size_t>(selected)];
    SendDlgItemMessageW(window, groupID, CB_SETCURSEL, selected, 0);
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const auto &field = dialog.config.fields[i];
        HWND control;
        if (field.boolean) {
            control = add(L"BUTTON", field.title.c_str(), BS_AUTOCHECKBOX | WS_TABSTOP, fieldBase + static_cast<int>(i));
            if (control) SendMessageW(control, BM_SETCHECK, field.value == L"1" ? BST_CHECKED : BST_UNCHECKED, 0);
        } else {
            if (!add(L"STATIC", field.title.c_str(), SS_LEFT, labelBase + static_cast<int>(i))) return false;
            if (field.choices.empty()) {
                control = add(L"EDIT", field.value.c_str(), ES_AUTOHSCROLL | WS_TABSTOP, fieldBase + static_cast<int>(i));
                if (control) SendMessageW(control, EM_LIMITTEXT, 65535, 0);
            } else {
                control = add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, fieldBase + static_cast<int>(i));
                if (control) {
                    for (size_t choice = 0; choice < field.choices.size(); ++choice) {
                        if (SendMessageW(control, CB_ADDSTRING, 0,
                            reinterpret_cast<LPARAM>(field.choices[choice].second.c_str())) < 0) return false;
                        if (field.choices[choice].first == field.value) SendMessageW(control, CB_SETCURSEL, choice, 0);
                    }
                }
            }
        }
        if (!control) return false;
    }
    if (!add(L"STATIC", L"&Recovered keyword edit (restoring adds to the current list):", SS_LEFT, recoveryLabelID) ||
        !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, recoveryID) ||
        !add(L"BUTTON", L"&Restore selected keywords", BS_PUSHBUTTON | WS_TABSTOP, restoreID)) return false;
    for (const auto &recovered : dialog.config.recovered) {
        if (SendDlgItemMessageW(window, recoveryID, CB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(recovered.c_str())) < 0) return false;
    }
    if (!dialog.config.recovered.empty()) SendDlgItemMessageW(window, recoveryID, CB_SETCURSEL, 0, 0);
    if (!add(L"BUTTON", L"Save and preview sta&rt", BS_PUSHBUTTON | WS_TABSTOP, previewStartID) ||
        !add(L"BUTTON", L"Save and preview sto&p", BS_PUSHBUTTON | WS_TABSTOP, previewStopID)) return false;
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
    if (action == 0 || action == 3 || action == 4 || action == 5) {
        for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
            const auto &field = dialog.config.fields[i];
            if (!field.choices.empty()) {
                const LRESULT selected = SendDlgItemMessageW(window, fieldBase + static_cast<int>(i), CB_GETCURSEL, 0, 0);
                if (selected < 0 || static_cast<size_t>(selected) >= field.choices.size()) {
                    SetDlgItemTextW(window, problemID, L"Choose a value for each preference first.");
                    return;
                }
                entries.push_back(jsti::utf8(field.choices[static_cast<size_t>(selected)].first));
                continue;
            }
            entries.push_back(field.boolean
                ? (SendDlgItemMessageW(window, fieldBase + static_cast<int>(i), BM_GETCHECK, 0, 0) == BST_CHECKED ? "1" : "0")
                : jsti::utf8(text(window, fieldBase + static_cast<int>(i))));
        }
        if (action == 3) {
            const LRESULT selected = SendDlgItemMessageW(window, recoveryID, CB_GETCURSEL, 0, 0);
            if (selected < 0 || static_cast<size_t>(selected) >= dialog.config.recovered.size()) {
                SetDlgItemTextW(window, problemID, L"Choose a recovered keyword edit first.");
                return;
            }
            entries.push_back(jsti::utf8(dialog.config.recovered[static_cast<size_t>(selected)]));
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
    if (action == 4 || action == 5) {
        SetDlgItemTextW(window, problemID, L"Preview request queued. Progress and errors appear on the main window.");
    } else DestroyWindow(window);
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
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 660), scale(window, 640)};
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == groupID && HIWORD(wparam) == CBN_SELCHANGE) {
            LRESULT selected = SendDlgItemMessageW(window, groupID, CB_GETCURSEL, 0, 0);
            if (selected >= 0 && static_cast<size_t>(selected) < dialog->groups.size()) {
                dialog->group = dialog->groups[static_cast<size_t>(selected)];
                layout(window, *dialog);
            }
            return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog, 0); return 0; }
        if (LOWORD(wparam) == importID) { apply(window, *dialog, 1); return 0; }
        if (LOWORD(wparam) == exportID) { apply(window, *dialog, 2); return 0; }
        if (LOWORD(wparam) == restoreID) { apply(window, *dialog, 3); return 0; }
        if (LOWORD(wparam) == previewStartID) { apply(window, *dialog, 4); return 0; }
        if (LOWORD(wparam) == previewStopID) { apply(window, *dialog, 5); return 0; }
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
        CW_USEDEFAULT, CW_USEDEFAULT, scale(owner, 700), scale(owner, 660), owner, nullptr, type.hInstance, &dialog);
}
} // namespace

void jsti_show_configuration(HWND owner, const wchar_t *group) {
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(configurationMutex); dialog.config = configuration; }
    dialog.group = group;
    if (!dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening configuration editor").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, groupID));
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
                                  const char *const *recovered_keywords, size_t recovered_count,
                                  JSTIConfigurationCallback callback, void *context) {
    if (!fields || !count || count > 32 || !callback || recovered_count > 1000 ||
        (recovered_count && !recovered_keywords)) return -1;
    Configuration updated;
    try {
        for (size_t i = 0; i < count; ++i) {
            Field field;
            if (!jsti::wide(fields[i].title, field.title) || !jsti::wide(fields[i].value, field.value) ||
                !jsti::wide(fields[i].group, field.group) ||
                field.value.size() > 65535 || (fields[i].is_boolean != 0 && fields[i].is_boolean != 1)) return -1;
            field.boolean = fields[i].is_boolean != 0;
            if (fields[i].choices && fields[i].choices[0]) {
                std::wstring choices;
                if (field.boolean || !jsti::wide(fields[i].choices, choices) || choices.size() > 65535) return -1;
                std::wistringstream stream(choices);
                std::wstring line;
                bool found = false;
                while (std::getline(stream, line)) {
                    const size_t tab = line.find(L'\t');
                    if (tab == std::wstring::npos || tab == 0 || tab + 1 == line.size() ||
                        line.find(L'\t', tab + 1) != std::wstring::npos || field.choices.size() >= 32) return -1;
                    const auto value = line.substr(0, tab);
                    found = found || value == field.value;
                    field.choices.emplace_back(value, line.substr(tab + 1));
                }
                if (!found) return -1;
            }
            updated.fields.push_back(std::move(field));
        }
        for (size_t i = 0; i < recovered_count; ++i) {
            std::wstring recovered;
            if (!jsti::wide(recovered_keywords[i], recovered) || recovered.size() > 65535) return -1;
            updated.recovered.push_back(std::move(recovered));
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
    dialog.config.fields = {{L"Language", L"en_GB", L"Transcription", false}, {L"HUD", L"1", L"General", true}};
    dialog.config.fields.push_back({L"Full HUD size", L"expanded", L"General", false,
        {{L"compact", L"Compact"}, {L"expanded", L"Always Expanded"}, {L"autoExpand", L"Auto-Expand"}}});
    dialog.config.context = &applied;
    dialog.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                 char *error, size_t capacity) {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        if (action != 0 || count != 3 || std::string(values[0]) != "fr_FR") {
            return jsti::fail("Synthetic invalid language.", error, capacity);
        }
        result.correct = std::string(values[1]) == "0" && std::string(values[2]) == "autoExpand";
        return 0;
    };
    HWND window = createDialog(owner, dialog);
    if (!window) { error = "Could not create the configuration fixture."; return false; }
    const bool initiallyGrouped = dialog.group == L"General" &&
        !(GetWindowLongW(GetDlgItem(window, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        (GetWindowLongW(GetDlgItem(window, fieldBase + 1), GWL_STYLE) & WS_VISIBLE);
    SendDlgItemMessageW(window, groupID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(groupID, CBN_SELCHANGE), 0);
    const bool switchedGroup = dialog.group == L"Transcription" &&
        (GetWindowLongW(GetDlgItem(window, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(window, fieldBase + 1), GWL_STYLE) & WS_VISIBLE);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool refused = IsWindow(window) && applied.calls == 1 && text(window, problemID) == L"Synthetic invalid language.";
    SetDlgItemTextW(window, fieldBase, L"fr_FR");
    SendDlgItemMessageW(window, fieldBase + 1, BM_SETCHECK, BST_UNCHECKED, 0);
    const bool choicePopulated = SendDlgItemMessageW(window, fieldBase + 2, CB_GETCOUNT, 0, 0) == 3 &&
        SendDlgItemMessageW(window, fieldBase + 2, CB_GETCURSEL, 0, 0) == 1;
    SendDlgItemMessageW(window, fieldBase + 2, CB_SETCURSEL, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool accepted = !IsWindow(window) && applied.calls == 2 && applied.correct;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog cancelled;
    cancelled.config = dialog.config;
    HWND second = createDialog(owner, cancelled);
    if (second) SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    const bool quiet = second && !IsWindow(second) && applied.calls == 2;
    if (!initiallyGrouped || !switchedGroup || !refused || !accepted || !quiet || !choicePopulated) {
        error = "Configuration editor did not group, validate, apply or cancel its native fields correctly.";
        return false;
    }
    Dialog recovery;
    recovery.config = dialog.config;
    recovery.group = L"Transcription";
    recovery.config.recovered = {L"First recoverable edit", L"Second recoverable edit"};
    recovery.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                   char *error, size_t capacity) {
        auto &result = *static_cast<Applied *>(context);
        if (action != 3 || count != 4 || std::string(values[0]) != "en_GB" ||
            std::string(values[2]) != "expanded" || std::string(values[3]) != "Second recoverable edit")
            return jsti::fail("Recovery selected the wrong edit.", error, capacity);
        ++result.calls;
        return 0;
    };
    HWND recoveryWindow = createDialog(owner, recovery);
    if (!recoveryWindow) { error = "Could not create the keyword recovery fixture."; return false; }
    const bool offered = (GetWindowLongW(GetDlgItem(recoveryWindow, recoveryID), GWL_STYLE) & WS_VISIBLE) &&
        SendDlgItemMessageW(recoveryWindow, recoveryID, CB_GETCOUNT, 0, 0) == 2;
    SendDlgItemMessageW(recoveryWindow, recoveryID, CB_SETCURSEL, 1, 0);
    SendMessageW(recoveryWindow, WM_COMMAND, MAKEWPARAM(restoreID, BN_CLICKED), 0);
    const bool restored = !IsWindow(recoveryWindow) && applied.calls == 3;
    if (IsWindow(recoveryWindow)) DestroyWindow(recoveryWindow);
    if (!offered || !restored) {
        error = "Recovered keyword picker did not emit the selected edit with current preference fields.";
        return false;
    }
    Dialog sounds;
    sounds.config.fields = {
        {L"Recording sounds", L"0", L"General", true},
        {L"Sound profile", L"classic", L"General", false,
            {{L"classic", L"Classic"}, {L"bubbly", L"Bubbly"}, {L"futuristic", L"Futuristic"}, {L"soft", L"Soft"}}},
        {L"Volume", L"0.7", L"General", false}
    };
    sounds.config.context = &applied;
    sounds.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                  char *error, size_t capacity) {
        if ((action != 4 && action != 5) || count != 3 || std::string(values[0]) != "0" ||
            std::string(values[1]) != "soft" || std::string(values[2]) != "0.25")
            return jsti::fail("Recording sound preview did not snapshot the edited preferences.", error, capacity);
        ++static_cast<Applied *>(context)->calls;
        return 0;
    };
    HWND soundWindow = createDialog(owner, sounds);
    if (!soundWindow) { error = "Could not create recording sound preferences fixture."; return false; }
    const bool profiles = SendDlgItemMessageW(soundWindow, fieldBase + 1, CB_GETCOUNT, 0, 0) == 4;
    SendDlgItemMessageW(soundWindow, fieldBase + 1, CB_SETCURSEL, 3, 0);
    SetDlgItemTextW(soundWindow, fieldBase + 2, L"0.25");
    SendMessageW(soundWindow, WM_COMMAND, MAKEWPARAM(previewStartID, BN_CLICKED), 0);
    SendMessageW(soundWindow, WM_COMMAND, MAKEWPARAM(previewStopID, BN_CLICKED), 0);
    const bool previewed = IsWindow(soundWindow) && applied.calls == 5;
    if (IsWindow(soundWindow)) DestroyWindow(soundWindow);
    if (!profiles || !previewed) {
        error = "Recording sound preferences did not offer all profiles or emit both previews.";
        return false;
    }
    return true;
}
