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
constexpr size_t maximumConfigurationFields = 64;
static_assert(maximumConfigurationFields <= labelBase - fieldBase);
constexpr UINT refreshTitleMessage = WM_APP + 85;
struct Field {
    std::wstring title, value, group;
    bool boolean = false;
    std::vector<std::pair<std::wstring, std::wstring>> choices{};
    bool requiresHandsFreeGuard = false;
    int enabledByField = 0;
    int availability = -1;
};
struct Configuration {
    std::vector<Field> fields;
    std::vector<std::wstring> recovered;
    JSTIConfigurationCallback callback = nullptr;
    void *context = nullptr;
};
Configuration configuration;
std::mutex configurationMutex;
HWND activeConfiguration = nullptr;
struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    std::vector<std::wstring> groups;
    std::wstring group = L"General";
    int scrollOffset = 0;
};
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void updateDependencies(HWND window, const Dialog &dialog) {
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const int enabling = dialog.config.fields[i].enabledByField;
        const int availability = dialog.config.fields[i].availability;
        if (!enabling && availability < 0) continue;
        const bool enabled = availability != 0 && (!enabling ||
            SendDlgItemMessageW(window, fieldBase + enabling - 1, BM_GETCHECK, 0, 0) == BST_CHECKED);
        EnableWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), enabled);
        EnableWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), enabled);
    }
}

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
    const int top = scale(window, 62), contentBottom = bounds.bottom - scale(window, 112);
    int contentHeight = 0;
    for (const auto &field : dialog.config.fields)
        if (field.group == dialog.group) contentHeight += scale(window, field.boolean ? 34 : 60);
    const bool recovery = dialog.group == L"Transcription" && !dialog.config.recovered.empty();
    const bool sounds = dialog.group == L"General";
    if (recovery) contentHeight += scale(window, 100);
    if (sounds) contentHeight += scale(window, 44);
    SCROLLINFO scroll{};
    scroll.cbSize = sizeof(scroll);
    scroll.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    scroll.nMin = 0; scroll.nMax = std::max(0, contentHeight - 1);
    scroll.nPage = static_cast<UINT>(std::max(1, contentBottom - top));
    scroll.nPos = dialog.scrollOffset;
    SetScrollInfo(window, SB_VERT, &scroll, TRUE);
    dialog.scrollOffset = GetScrollPos(window, SB_VERT);
    int y = top - dialog.scrollOffset, margin = scale(window, 20), width = bounds.right - 2 * margin;
    MoveWindow(GetDlgItem(window, groupLabelID), margin, scale(window, 20), scale(window, 90), scale(window, 24), TRUE);
    MoveWindow(GetDlgItem(window, groupID), margin + scale(window, 90), scale(window, 16),
        width - scale(window, 90), scale(window, 200), TRUE);
    for (size_t i = 0; i < dialog.config.fields.size(); ++i) {
        const auto &field = dialog.config.fields[i];
        const int rowHeight = scale(window, field.boolean ? 34 : 60);
        const bool inGroup = field.group == dialog.group;
        const bool visible = inGroup && y >= top && y + rowHeight <= contentBottom;
        ShowWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), visible ? SW_SHOW : SW_HIDE);
        ShowWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), visible ? SW_SHOW : SW_HIDE);
        if (!inGroup) continue;
        if (!visible) { y += rowHeight; continue; }
        const bool boolean = dialog.config.fields[i].boolean;
        if (!boolean) {
            MoveWindow(GetDlgItem(window, labelBase + static_cast<int>(i)), margin, y, width, scale(window, 20), TRUE);
            y += scale(window, 22);
        }
        MoveWindow(GetDlgItem(window, fieldBase + static_cast<int>(i)), margin, y, width,
            scale(window, dialog.config.fields[i].choices.empty() ? 28 : 200), TRUE);
        y += scale(window, boolean ? 34 : 38);
    }
    const bool showSounds = sounds && y >= top && y + scale(window, 44) <= contentBottom;
    for (int id : {previewStartID, previewStopID}) ShowWindow(GetDlgItem(window, id), showSounds ? SW_SHOW : SW_HIDE);
    if (sounds) {
        const int half = (width - scale(window, 8)) / 2;
        MoveWindow(GetDlgItem(window, previewStartID), margin, y, half, scale(window, 32), TRUE);
        MoveWindow(GetDlgItem(window, previewStopID), margin + half + scale(window, 8), y, half, scale(window, 32), TRUE);
        y += scale(window, 44);
    }
    for (int id : {recoveryLabelID, recoveryID, restoreID})
        ShowWindow(GetDlgItem(window, id),
            recovery && y >= top && y + scale(window, 100) <= contentBottom ? SW_SHOW : SW_HIDE);
    if (recovery) {
        MoveWindow(GetDlgItem(window, recoveryLabelID), margin, y, width, scale(window, 20), TRUE);
        y += scale(window, 24);
        MoveWindow(GetDlgItem(window, recoveryID), margin, y, width, scale(window, 200), TRUE);
        y += scale(window, 36);
        MoveWindow(GetDlgItem(window, restoreID), margin, y, scale(window, 220), scale(window, 32), TRUE);
        y += scale(window, 40);
    }
    MoveWindow(GetDlgItem(window, problemID), margin, contentBottom + scale(window, 8), width, scale(window, 44), TRUE);
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
        if (field.requiresHandsFreeGuard && !jsti_window_hands_free_guard_ready()) {
            EnableWindow(control, field.value == L"1");
            SetWindowTextW(control, L"Hands-free unavailable: session lock/sleep monitoring required");
        }
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
    updateDependencies(window, dialog);
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
    case WM_VSCROLL: {
        SCROLLINFO scroll{};
        scroll.cbSize = sizeof(scroll);
        scroll.fMask = SIF_ALL;
        GetScrollInfo(window, SB_VERT, &scroll);
        switch (LOWORD(wparam)) {
        case SB_LINEUP: dialog->scrollOffset -= scale(window, 34); break;
        case SB_LINEDOWN: dialog->scrollOffset += scale(window, 34); break;
        case SB_PAGEUP: dialog->scrollOffset -= static_cast<int>(scroll.nPage); break;
        case SB_PAGEDOWN: dialog->scrollOffset += static_cast<int>(scroll.nPage); break;
        case SB_THUMBTRACK: dialog->scrollOffset = scroll.nTrackPos; break;
        case SB_TOP: dialog->scrollOffset = 0; break;
        case SB_BOTTOM: dialog->scrollOffset = scroll.nMax; break;
        default: return 0;
        }
        layout(window, *dialog);
        return 0;
    }
    case WM_MOUSEWHEEL:
        dialog->scrollOffset -= GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA * scale(window, 60);
        layout(window, *dialog);
        return 0;
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
                dialog->scrollOffset = 0;
                layout(window, *dialog);
            }
            return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) >= fieldBase &&
            static_cast<size_t>(LOWORD(wparam) - fieldBase) < dialog->config.fields.size())
            updateDependencies(window, *dialog);
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog, 0); return 0; }
        if (LOWORD(wparam) == importID) { apply(window, *dialog, 1); return 0; }
        if (LOWORD(wparam) == exportID) { apply(window, *dialog, 2); return 0; }
        if (LOWORD(wparam) == restoreID) { apply(window, *dialog, 3); return 0; }
        if (LOWORD(wparam) == previewStartID) { apply(window, *dialog, 4); return 0; }
        if (LOWORD(wparam) == previewStopID) { apply(window, *dialog, 5); return 0; }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case refreshTitleMessage: {
        const size_t index = static_cast<size_t>(wparam);
        std::wstring title;
        int availability;
        {
            std::lock_guard<std::mutex> lock(configurationMutex);
            if (index >= configuration.fields.size() || index >= dialog->config.fields.size()) return 0;
            title = configuration.fields[index].title;
            availability = configuration.fields[index].availability;
        }
        dialog->config.fields[index].title = title;
        SetDlgItemTextW(window, labelBase + static_cast<int>(index), title.c_str());
        dialog->config.fields[index].availability = availability;
        updateDependencies(window, *dialog);
        return 0;
    }
    case WM_DESTROY:
        {
            std::lock_guard<std::mutex> lock(configurationMutex);
            if (activeConfiguration == window) activeConfiguration = nullptr;
        }
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
        L"Dictation preferences - Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VSCROLL,
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
    { std::lock_guard<std::mutex> lock(configurationMutex); activeConfiguration = window; }
    for (size_t index = 0; index < dialog.config.fields.size(); ++index)
        if (!dialog.config.fields[index].boolean) SendMessageW(window, refreshTitleMessage, index, 0);
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, groupID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (message.message == WM_KEYDOWN && (message.wParam == VK_NEXT || message.wParam == VK_PRIOR)) {
            wchar_t kind[32]{};
            GetClassNameW(GetFocus(), kind, 32);
            if (wcscmp(kind, L"ComboBox") != 0) {
                SendMessageW(window, WM_VSCROLL, message.wParam == VK_NEXT ? SB_PAGEDOWN : SB_PAGEUP, 0);
                continue;
            }
        }
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
    if (!fields || !count || count > maximumConfigurationFields || !callback || recovered_count > 1000 ||
        (recovered_count && !recovered_keywords)) return -1;
    Configuration updated;
    try {
        for (size_t i = 0; i < count; ++i) {
            Field field;
            if (!jsti::wide(fields[i].title, field.title) || !jsti::wide(fields[i].value, field.value) ||
                !jsti::wide(fields[i].group, field.group) ||
                field.value.size() > 65535 || (fields[i].is_boolean != 0 && fields[i].is_boolean != 1)) return -1;
            field.boolean = fields[i].is_boolean != 0;
            if (fields[i].requires_hands_free_guard != 0 && fields[i].requires_hands_free_guard != 1) return -1;
            field.requiresHandsFreeGuard = fields[i].requires_hands_free_guard != 0;
            if (field.requiresHandsFreeGuard && !field.boolean) return -1;
            field.enabledByField = fields[i].enabled_by_field;
            if (field.enabledByField < 0 || static_cast<size_t>(field.enabledByField) > count ||
                (field.enabledByField && (field.enabledByField == static_cast<int>(i + 1) ||
                    fields[field.enabledByField - 1].is_boolean != 1))) return -1;
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

int jsti_window_set_configuration_field_title(size_t index, const char *title) {
    if (index >= maximumConfigurationFields || !title) return -1;
    try {
        std::wstring updated;
        if (!jsti::wide(title, updated) || updated.empty() || updated.size() > 256) return -1;
        std::lock_guard<std::mutex> lock(configurationMutex);
        if (configuration.fields.empty()) return 1;
        if (index >= configuration.fields.size() || configuration.fields[index].boolean) return -1;
        configuration.fields[index].title = std::move(updated);
        if (activeConfiguration && !PostMessageW(activeConfiguration, refreshTitleMessage, index, 0)) return -1;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled) {
    if (index >= maximumConfigurationFields || (enabled != 0 && enabled != 1)) return -1;
    std::lock_guard<std::mutex> lock(configurationMutex);
    if (configuration.fields.empty()) return 1;
    if (index >= configuration.fields.size() || configuration.fields[index].boolean ||
        configuration.fields[index].enabledByField != 0) return -1;
    configuration.fields[index].availability = enabled;
    return activeConfiguration && !PostMessageW(activeConfiguration, refreshTitleMessage, index, 0) ? -1 : 0;
}

static bool configurationTitleSelfTest(HWND owner, std::string &error) {
    Dialog fixture;
    fixture.config.fields = {{L"Soniox voice language", L"en_GB", L"Voice Output", false}};
    fixture.group = L"Voice Output";
    HWND window = createDialog(owner, fixture);
    if (!window) { error = "Could not create the Voice language label fixture."; return false; }
    Configuration previous;
    HWND previousWindow;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        previous = configuration;
        previousWindow = activeConfiguration;
        configuration = fixture.config;
        activeConfiguration = window;
    }
    SetDlgItemTextW(window, fieldBase, L"fr_FR");
    const bool queued = jsti_window_set_configuration_field_title(0, "Gemini voice language") == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    const bool preserved = text(window, labelBase) == L"Gemini voice language" &&
        text(window, fieldBase) == L"fr_FR";
    const bool refused = jsti_window_set_configuration_field_title(32, "Invalid") < 0 &&
        jsti_window_set_configuration_field_title(0, nullptr) < 0 &&
        jsti_window_set_configuration_field_title(0, "") < 0 &&
        jsti_window_set_configuration_field_enabled(32, 1) < 0 &&
        jsti_window_set_configuration_field_enabled(0, 2) < 0;
    bool availabilityPreserved = jsti_window_set_configuration_field_enabled(0, 0) == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    availabilityPreserved = availabilityPreserved && !IsWindowEnabled(GetDlgItem(window, fieldBase)) &&
        text(window, fieldBase) == L"fr_FR" && jsti_window_set_configuration_field_enabled(0, 1) == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    availabilityPreserved = availabilityPreserved && IsWindowEnabled(GetDlgItem(window, fieldBase)) &&
        text(window, fieldBase) == L"fr_FR";
    DestroyWindow(window);
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(previous);
        activeConfiguration = previousWindow;
    }
    if (!queued || !preserved || !refused || !availabilityPreserved) {
        error = "Voice language label update replaced an unsaved value or accepted invalid metadata.";
        return false;
    }
    return true;
}

static bool configurationAutoCleanSelfTest(HWND owner, std::string &error) {
    Configuration previous;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        previous = configuration;
    }
    struct Applied { int calls = 0; bool correct = false; } applied;
    const auto callback = [](int action, const char *const *values, size_t count, void *context,
                              char *, size_t) -> int {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        result.correct = action == 0 && count == 33 &&
            std::string(values[0]) == "preserved" && std::string(values[28]) == "instant" &&
            std::string(values[29]) == "fixture/model" && std::string(values[30]) == "250" &&
            std::string(values[31]) == "3" && std::string(values[32]) == "0";
        return result.correct ? 0 : -1;
    };
    std::vector<JSTIConfigurationField> fields(33);
    for (auto &field : fields) {
        field.title = "Existing setting"; field.value = "preserved"; field.group = "General";
    }
    fields[28].title = "Live processing speed"; fields[28].value = "livePolish";
    fields[28].choices = "instant\tInstant\nlivePolish\tAuto-Clean";
    fields[29].title = "Auto-Clean model"; fields[29].value = "captured/model";
    fields[30].title = "Auto-Clean debounce"; fields[30].value = "500";
    fields[31].title = "Auto-Clean minimum delta"; fields[31].value = "20";
    fields[32].title = "Skip ordinary cleanup"; fields[32].value = "1"; fields[32].is_boolean = 1;
    for (size_t index = 28; index < fields.size(); ++index) fields[index].group = "Transcription";
    const bool registered = jsti_window_set_configuration(
        fields.data(), fields.size(), nullptr, 0, callback, &applied) == 0;
    Dialog fixture;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        fixture.config = configuration;
    }
    fixture.group = L"Transcription";
    HWND window = registered ? createDialog(owner, fixture) : nullptr;
    bool accepted = false;
    if (window) {
        const bool populated = IsWindow(GetDlgItem(window, fieldBase + 32)) &&
            SendDlgItemMessageW(window, fieldBase + 28, CB_GETCOUNT, 0, 0) == 2 &&
            SendDlgItemMessageW(window, fieldBase + 28, CB_GETCURSEL, 0, 0) == 1;
        SendDlgItemMessageW(window, fieldBase + 28, CB_SETCURSEL, 0, 0);
        SetDlgItemTextW(window, fieldBase + 29, L"fixture/model");
        SetDlgItemTextW(window, fieldBase + 30, L"250");
        SetDlgItemTextW(window, fieldBase + 31, L"3");
        SendDlgItemMessageW(window, fieldBase + 32, BM_SETCHECK, BST_UNCHECKED, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
        accepted = populated && !IsWindow(window) && applied.calls == 1 && applied.correct;
        if (IsWindow(window)) DestroyWindow(window);
    }
    const bool bounded = jsti_window_set_configuration(
        fields.data(), maximumConfigurationFields + 1, nullptr, 0, callback, &applied) < 0;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(previous);
    }
    if (!registered || !accepted || !bounded) {
        error = "Auto-Clean preferences did not register or apply past the former 32-field limit.";
        return false;
    }
    return true;
}

bool jsti_configuration_self_test(HWND owner, std::string &error) {
    if (!configurationTitleSelfTest(owner, error)) return false;
    if (!configurationAutoCleanSelfTest(owner, error)) return false;
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
    Dialog overflow;
    Dialog commands;
    commands.config.fields = {
        {L"Enable voice commands", L"0", L"General", true},
        {L"Clipboard triggers", L"my snippet", L"General", false, {}, false, 1}
    };
    HWND commandWindow = createDialog(owner, commands);
    if (!commandWindow) { error = "Could not create voice command preferences fixture."; return false; }
    const bool commandsDisabled = !IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1));
    SendDlgItemMessageW(commandWindow, fieldBase, BM_SETCHECK, BST_CHECKED, 0);
    SendMessageW(commandWindow, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    const bool enabled = IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1));
    SendDlgItemMessageW(commandWindow, fieldBase, BM_SETCHECK, BST_UNCHECKED, 0);
    SendMessageW(commandWindow, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    const bool retained = !IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1)) &&
        text(commandWindow, fieldBase + 1) == L"my snippet";
    DestroyWindow(commandWindow);
    if (!commandsDisabled || !enabled || !retained) {
        error = "Voice command toggle did not enable/disable its retained trigger editor.";
        return false;
    }
    overflow.group = L"Transcription";
    for (int i = 0; i < 12; ++i)
        overflow.config.fields.push_back({L"Preference", L"0.05", L"Transcription", false});
    overflow.config.fields.push_back({L"Hands-free sound activation", L"1", L"Transcription", true, {}, true});
    overflow.config.recovered = {L"Recoverable edit"};
    HWND overflowWindow = createDialog(owner, overflow);
    if (!overflowWindow) { error = "Could not create scrolling preferences fixture."; return false; }
    RECT before{}, after{}, recoveryBounds{}, client{};
    GetWindowRect(GetDlgItem(overflowWindow, IDOK), &before);
    SendMessageW(overflowWindow, WM_VSCROLL, SB_BOTTOM, 0);
    GetWindowRect(GetDlgItem(overflowWindow, IDOK), &after);
    GetWindowRect(GetDlgItem(overflowWindow, restoreID), &recoveryBounds);
    MapWindowPoints(nullptr, overflowWindow, reinterpret_cast<POINT *>(&recoveryBounds), 2);
    GetClientRect(overflowWindow, &client);
    const bool reached = (GetWindowLongW(GetDlgItem(overflowWindow, restoreID), GWL_STYLE) & WS_VISIBLE) &&
        (GetWindowLongW(GetDlgItem(overflowWindow, fieldBase + 12), GWL_STYLE) & WS_VISIBLE) &&
        recoveryBounds.bottom <= client.bottom - scale(overflowWindow, 112) &&
        EqualRect(&before, &after) &&
        IsWindowEnabled(GetDlgItem(overflowWindow, fieldBase + 12));
    SendMessageW(overflowWindow, WM_VSCROLL, SB_TOP, 0);
    const bool returned = (GetWindowLongW(GetDlgItem(overflowWindow, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(overflowWindow, restoreID), GWL_STYLE) & WS_VISIBLE);
    DestroyWindow(overflowWindow);
    if (!reached || !returned) {
        error = "Preferences scrolling did not expose the last field and recovery controls above the fixed footer.";
        return false;
    }
    overflow.config.fields[12].value = L"0";
    overflowWindow = createDialog(owner, overflow);
    if (!overflowWindow) { error = "Could not create disabled hands-free preferences fixture."; return false; }
    const bool disabled = IsWindowEnabled(GetDlgItem(overflowWindow, fieldBase + 12)) ==
        (jsti_window_hands_free_guard_ready() != 0);
    DestroyWindow(overflowWindow);
    if (!disabled) {
        error = "Unavailable hands-free preferences allowed enabling a new unmonitored mode.";
        return false;
    }
    return true;
}
