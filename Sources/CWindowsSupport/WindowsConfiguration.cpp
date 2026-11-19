#include "WindowsConfigurationInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <algorithm>
#include <commdlg.h>
#include <cstring>
#include <mutex>
#include <sstream>
#include <utility>
#include <vector>

namespace jsti::configuration {
namespace {
// The host's latest description and the open editor, guarded by configurationMutex.
Configuration configuration;
std::mutex configurationMutex;
HWND activeConfiguration = nullptr;
} // namespace

Configuration hostConfiguration() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}
Configuration exchangeConfiguration(Configuration next) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return std::exchange(configuration, std::move(next));
}
HWND exchangeActiveEditor(HWND next) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return std::exchange(activeConfiguration, next);
}

using jsti::chrome::scale;

static void updateDependencies(HWND window, const Dialog &dialog) {
    if (dialog.pending) {
        for (HWND control : dialog.controls) EnableWindow(control, GetDlgCtrlID(control) == IDCANCEL);
        return;
    }
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

static bool acknowledge(const Configuration &config) {
    if (config.revision.empty()) return true;
    const char *value = config.revision.c_str();
    char error[1024]{};
    if (config.callback(6, &value, 1, config.context, error, sizeof(error)) == 0) return true;
    jsti_window_update(error[0] ? error : "Could not acknowledge the preferences view.", nullptr, -1);
    return false;
}

static void layout(HWND window, Dialog &dialog) {
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

static bool controls(HWND window, Dialog &dialog) {
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
    dialog.font = jsti::chrome::dialogFont(window);
    if (dialog.font)
        for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(dialog.font), TRUE);
    layout(window, dialog);
    updateDependencies(window, dialog);
    return true;
}

static void apply(HWND window, Dialog &dialog, int action) {
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
    if (!dialog.config.revision.empty() && (action == 0 || action == 3 || action == 4 || action == 5))
        entries.push_back(dialog.config.revision);
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
        if (!dialog.config.revision.empty()) {
            dialog.pending = true;
            updateDependencies(window, dialog);
        }
    } else DestroyWindow(window);
}

static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = jsti::chrome::dialogInstance<Dialog>(window, message, lparam);
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
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
        jsti::chrome::applySuggestedBounds(window, lparam);
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = jsti::chrome::dialogFont(window);
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
    case refreshSnapshotMessage: {
        Configuration updated;
        { std::lock_guard<std::mutex> lock(configurationMutex); updated = configuration; }
        for (HWND control : dialog->controls) DestroyWindow(control);
        dialog->controls.clear();
        dialog->groups.clear();
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr;
        dialog->pending = false;
        dialog->config = std::move(updated);
        if (!controls(window, *dialog)) { DestroyWindow(window); return 0; }
        return acknowledge(dialog->config) ? 1 : 0;
    }
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

bool revealField(HWND window, Dialog &dialog, size_t index) {
    if (index >= dialog.config.fields.size() || dialog.config.fields[index].group != dialog.group) return false;
    int offset = 0;
    for (size_t i = 0; i < index; ++i)
        if (dialog.config.fields[i].group == dialog.group) offset += scale(window, dialog.config.fields[i].boolean ? 34 : 60);
    dialog.scrollOffset = offset;
    layout(window, dialog);
    HWND control = GetDlgItem(window, fieldBase + static_cast<int>(index));
    if (!control || !(GetWindowLongW(control, GWL_STYLE) & WS_VISIBLE)) return false;
    if (IsWindowEnabled(control)) {
        SetFocus(control);
        wchar_t kind[16]{};
        GetClassNameW(control, kind, 16);
        if (_wcsicmp(kind, L"Edit") == 0) SendMessageW(control, EM_SETSEL, 0, -1);
    }
    return true;
}
} // namespace jsti::configuration

using namespace jsti::configuration;

bool jsti_configuration_field_available(size_t index) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback && index < configuration.fields.size();
}

static void showConfiguration(HWND owner, const wchar_t *group, size_t focusField);

void jsti_show_configuration(HWND owner, const wchar_t *group) {
    showConfiguration(owner, group, static_cast<size_t>(-1));
}

void jsti_show_configuration_field(HWND owner, size_t index) {
    std::wstring group;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        if (!configuration.callback || index >= configuration.fields.size()) return;
        group = configuration.fields[index].group;
    }
    showConfiguration(owner, group.c_str(), index);
}

static void showConfiguration(HWND owner, const wchar_t *group, size_t focusField) {
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
    if (focusField != static_cast<size_t>(-1)) revealField(window, dialog, focusField);
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

static int setConfiguration(const JSTIConfigurationField *fields, size_t count,
                                  const char *const *recovered_keywords, size_t recovered_count,
                                  JSTIConfigurationCallback callback, void *context, const char *revision) {
    if (!fields || !count || count > maximumConfigurationFields || !callback || recovered_count > 1000 ||
        (recovered_count && !recovered_keywords)) return -1;
    Configuration updated;
    try {
        if (revision) {
            if (!revision[0] || std::strlen(revision) > 64) return -1;
            updated.revision = revision;
        }
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
                if (field.boolean || !jsti::wide(fields[i].choices, choices) || choices.size() > 65535 ||
                    choices.back() == L'\n') return -1;
                std::wistringstream stream(choices);
                std::wstring line;
                bool found = false;
                while (std::getline(stream, line)) {
                    const size_t tab = line.find(L'\t');
                    if (tab == std::wstring::npos || tab + 1 == line.size() ||
                        line.find(L'\t', tab + 1) != std::wstring::npos || field.choices.size() >= 32) return -1;
                    const auto value = line.substr(0, tab);
                    if (std::any_of(field.choices.begin(), field.choices.end(),
                        [&](const auto &choice) { return choice.first == value; })) return -1;
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
        HWND window;
        {
            std::lock_guard<std::mutex> lock(configurationMutex);
            configuration = updated;
            window = activeConfiguration;
        }
        if (revision) {
            if (window && IsWindow(window)) {
                DWORD_PTR rendered = 0;
                if (!SendMessageTimeoutW(window, refreshSnapshotMessage, 0, 0,
                    SMTO_BLOCK | SMTO_ABORTIFHUNG, 5000, &rendered) || rendered != 1) return -1;
            } else if (!acknowledge(updated)) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recoveredCount, JSTIConfigurationCallback callback, void *context) {
    return setConfiguration(fields, count, recovered, recoveredCount, callback, context, nullptr);
}

int jsti_window_set_configuration_revision(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recoveredCount, JSTIConfigurationCallback callback,
    void *context, const char *revision) {
    return revision ? setConfiguration(fields, count, recovered, recoveredCount, callback, context, revision) : -1;
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
