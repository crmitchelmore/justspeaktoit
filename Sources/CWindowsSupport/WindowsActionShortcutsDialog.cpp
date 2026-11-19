#include "WindowsActionShortcutsInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commctrl.h>

namespace jsti::actionShortcuts {
namespace {
using jsti::chrome::scale;

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), row = at(28), button = at(32), gap = at(8), buttonWidth = at(100);
    const int right = static_cast<int>(bounds.right), width = right - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    int y = static_cast<int>(bounds.bottom) - margin - button;
    move(IDOK, right - margin - 2 * buttonWidth - gap, y, buttonWidth, button);
    move(IDCANCEL, right - margin - buttonWidth, y, buttonWidth, button);
    y -= gap + at(64);
    move(statusID, margin, y, width, at(64));
    y -= gap + row;
    move(presetLabelID, margin, y + at(4), at(70), at(22));
    move(presetID, margin + at(76), y, at(200), at(200));
    move(resetID, margin + at(286), y, at(170), row);
    y -= gap + at(24);
    move(enabledID, margin, y, at(120), at(24));
    move(globalID, margin + at(130), y, at(200), at(24));
    move(noteID, margin + at(340), y + at(2), std::max(at(40), width - at(340)), at(22));
    y -= gap + row;
    move(keyLabelID, margin, y + at(4), at(200), at(22));
    move(keyID, margin + at(206), y, at(220), row);
    move(clearID, margin + at(434), y, at(90), row);
    move(introID, margin, at(16), width, at(40));
    const int top = at(60);
    move(listID, margin, top, width, std::max(at(80), y - gap - top));
    HWND list = GetDlgItem(window, listID);
    const int columns = width - at(24);
    const int widths[] = {columns * 34 / 100, columns * 20 / 100, columns * 14 / 100,
                          columns - columns * 34 / 100 - columns * 20 / 100 - columns * 14 / 100};
    for (int column = 0; column < 4; ++column) ListView_SetColumnWidth(list, column, widths[column]);
}

void refreshFont(HWND window, Dialog &dialog) { jsti::chrome::refreshDialogFont(window, dialog.controls, dialog.font); }
} // namespace

WORD hotkeyValue(UINT modifiers, UINT key) {
    BYTE flags = 0;
    if (modifiers & MOD_SHIFT) flags |= HOTKEYF_SHIFT;
    if (modifiers & MOD_CONTROL) flags |= HOTKEYF_CONTROL;
    if (modifiers & MOD_ALT) flags |= HOTKEYF_ALT;
    if (extendedKey(key)) flags |= HOTKEYF_EXT;
    return MAKEWORD(static_cast<BYTE>(key), flags);
}

namespace {
void setCell(HWND list, int item, int column, const std::wstring &text) {
    LVITEMW cell{};
    cell.iSubItem = column;
    cell.pszText = const_cast<wchar_t *>(text.c_str());
    SendMessageW(list, LVM_SETITEMTEXTW, static_cast<WPARAM>(item), reinterpret_cast<LPARAM>(&cell));
}

void showRow(HWND window, const Dialog &dialog, int index) {
    const Row &row = dialog.config.rows[static_cast<size_t>(index)];
    HWND list = GetDlgItem(window, listID);
    setCell(list, index, 1, comboName(row.modifiers, row.key));
    setCell(list, index, 2, whereText(row));
    setCell(list, index, 3, noteText(row));
}

int matchingPreset(const Dialog &dialog) {
    for (size_t preset = 0; preset < dialog.config.presets.size(); ++preset) {
        const auto &rows = dialog.config.presets[preset];
        bool same = rows.size() == dialog.config.rows.size();
        for (size_t index = 0; same && index < rows.size(); ++index) {
            const Row &left = rows[index], &right = dialog.config.rows[index];
            same = left.modifiers == right.modifiers && left.key == right.key && left.enabled == right.enabled &&
                left.global == right.global;
        }
        if (same) return static_cast<int>(preset);
    }
    return static_cast<int>(dialog.config.presets.size());  // "Custom"
}

std::wstring lines(const char *text) {
    std::wstring wide, result;
    if (!jsti::wide(text, wide)) return L"";
    for (wchar_t character : wide) {
        if (character == L'\n' && (result.empty() || result.back() != L'\r')) result += L'\r';
        result += character;
    }
    return result;
}

// Asks the host about the edited rows. Returns the host's verdict.
int check(HWND window, Dialog &dialog, bool commit) {
    if (!dialog.config.callback) return -1;
    char message[4096] = {};
    const auto rows = view(dialog.config.rows);
    const int result = dialog.config.callback(rows.data(), rows.size(), commit ? 1 : 0, message, sizeof(message),
                                              dialog.config.context);
    message[sizeof(message) - 1] = 0;
    SetDlgItemTextW(window, statusID, lines(message).c_str());
    return result == 0 ? 0 : -1;
}

void loadDetail(HWND window, Dialog &dialog) {
    dialog.loading = true;
    const bool valid = dialog.selected >= 0 && static_cast<size_t>(dialog.selected) < dialog.config.rows.size();
    Row empty;
    const Row &row = valid ? dialog.config.rows[static_cast<size_t>(dialog.selected)] : empty;
    const std::wstring label = valid ? L"&Shortcut for " + row.wideTitle : L"&Shortcut";
    SetDlgItemTextW(window, keyLabelID, label.c_str());
    SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, row.key ? hotkeyValue(row.modifiers, row.key) : 0, 0);
    CheckDlgButton(window, enabledID, row.enabled ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(window, globalID, row.global ? BST_CHECKED : BST_UNCHECKED);
    SetDlgItemTextW(window, noteID, noteText(row).c_str());
    for (int id : {keyID, clearID, enabledID}) EnableWindow(GetDlgItem(window, id), valid);
    EnableWindow(GetDlgItem(window, globalID), valid && row.canBeGlobal);
    dialog.loading = false;
}

void edited(HWND window, Dialog &dialog) {
    if (dialog.selected >= 0) showRow(window, dialog, dialog.selected);
    if (dialog.selected >= 0) {
        SetDlgItemTextW(window, noteID, noteText(dialog.config.rows[static_cast<size_t>(dialog.selected)]).c_str());
    }
    SendDlgItemMessageW(window, presetID, CB_SETCURSEL, static_cast<WPARAM>(matchingPreset(dialog)), 0);
    check(window, dialog, false);
}
} // namespace

void readDetail(HWND window, Dialog &dialog) {
    if (dialog.loading || dialog.selected < 0) return;
    Row &row = dialog.config.rows[static_cast<size_t>(dialog.selected)];
    const WORD value = static_cast<WORD>(SendDlgItemMessageW(window, keyID, HKM_GETHOTKEY, 0, 0));
    const UINT key = LOBYTE(value), flags = HIBYTE(value);
    const UINT modifiers = ((flags & HOTKEYF_ALT) ? MOD_ALT : 0) | ((flags & HOTKEYF_CONTROL) ? MOD_CONTROL : 0) |
        ((flags & HOTKEYF_SHIFT) ? MOD_SHIFT : 0);
    // A modifier on its own is still being typed.
    if (key && !modifierKey(key)) { row.key = key; row.modifiers = modifiers; }
    else if (!key && !modifiers) { row.key = 0; row.modifiers = 0; }
    row.enabled = IsDlgButtonChecked(window, enabledID) == BST_CHECKED;
    if (row.canBeGlobal) row.global = IsDlgButtonChecked(window, globalID) == BST_CHECKED;
    edited(window, dialog);
}

namespace {
void applyPreset(HWND window, Dialog &dialog, int preset) {
    if (preset < 0 || static_cast<size_t>(preset) >= dialog.config.presets.size()) return;
    const auto &rows = dialog.config.presets[static_cast<size_t>(preset)];
    for (size_t index = 0; index < rows.size() && index < dialog.config.rows.size(); ++index) {
        Row &row = dialog.config.rows[index];
        row.modifiers = rows[index].modifiers;
        row.key = rows[index].key;
        row.enabled = rows[index].enabled;
        row.global = rows[index].global;
    }
    for (size_t index = 0; index < dialog.config.rows.size(); ++index) showRow(window, dialog, static_cast<int>(index));
    loadDetail(window, dialog);
    edited(window, dialog);
}

bool createControls(HWND window, Dialog &dialog) {
    INITCOMMONCONTROLSEX classes{sizeof(classes), ICC_HOTKEY_CLASS | ICC_LISTVIEW_CLASSES};
    if (!InitCommonControlsEx(&classes)) return false;
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Shortcuts for individual actions. They are shared with Just Speak to It on your Mac; "
            L"actions marked Mac only are kept for it.", SS_LEFT, introID) &&
        add(WC_LISTVIEWW, L"", LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | WS_BORDER | WS_TABSTOP, listID) &&
        add(L"STATIC", L"&Shortcut", 0, keyLabelID) &&
        add(HOTKEY_CLASSW, L"", WS_TABSTOP | WS_BORDER, keyID) &&
        add(L"BUTTON", L"C&lear", BS_PUSHBUTTON | WS_TABSTOP, clearID) &&
        add(L"BUTTON", L"&Enabled", BS_AUTOCHECKBOX | WS_TABSTOP, enabledID) &&
        add(L"BUTTON", L"Works in &other apps", BS_AUTOCHECKBOX | WS_TABSTOP, globalID) &&
        add(L"STATIC", L"", SS_LEFT | SS_ENDELLIPSIS, noteID) &&
        add(L"STATIC", L"&Preset", 0, presetLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, presetID) &&
        add(L"BUTTON", L"&Reset to defaults", BS_PUSHBUTTON | WS_TABSTOP, resetID) &&
        add(L"STATIC", L"", SS_LEFT, statusID) &&
        add(L"BUTTON", L"&Save", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    HWND list = GetDlgItem(window, listID);
    ListView_SetExtendedListViewStyle(list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
    const wchar_t *titles[] = {L"Action", L"Shortcut", L"Where", L"Note"};
    for (int column = 0; column < 4; ++column) {
        LVCOLUMNW header{};
        header.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
        header.pszText = const_cast<wchar_t *>(titles[column]);
        header.cx = 100;
        header.iSubItem = column;
        if (SendMessageW(list, LVM_INSERTCOLUMNW, static_cast<WPARAM>(column), reinterpret_cast<LPARAM>(&header)) < 0)
            return false;
    }
    for (size_t index = 0; index < dialog.config.rows.size(); ++index) {
        LVITEMW item{};
        item.mask = LVIF_TEXT;
        item.iItem = static_cast<int>(index);
        item.pszText = const_cast<wchar_t *>(dialog.config.rows[index].wideTitle.c_str());
        if (SendMessageW(list, LVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&item)) < 0) return false;
        showRow(window, dialog, static_cast<int>(index));
    }
    for (const auto &name : dialog.config.presetNames) {
        const LRESULT added = SendDlgItemMessageW(window, presetID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
    }
    SendDlgItemMessageW(window, presetID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Custom"));
    SendDlgItemMessageW(window, presetID, CB_SETCURSEL, static_cast<WPARAM>(matchingPreset(dialog)), 0);
    EnableWindow(GetDlgItem(window, resetID), !dialog.config.presets.empty());
    refreshFont(window, dialog);
    layout(window);
    dialog.selected = dialog.config.rows.empty() ? -1 : 0;
    if (dialog.selected == 0) ListView_SetItemState(list, 0, LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
    loadDetail(window, dialog);
    check(window, dialog, false);
    return true;
}
} // namespace

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

namespace {
void save(HWND window, Dialog &dialog) {
    if (dialog.saved || check(window, dialog, false) != 0) return;
    // Probe the new set before the host stores it; a refusal keeps the old one.
    const auto failures = registerRows(dialog.config.rows);
    if (!failures.empty()) {
        registerRows(runtime().rows);
        const std::wstring message = failureText(failures).substr(0, failureText(failures).find(L", so it")) +
            L". Choose another shortcut or turn off Works in other apps.";
        SetDlgItemTextW(window, statusID, message.c_str());
        return;
    }
    if (check(window, dialog, true) != 0) {
        registerRows(runtime().rows);
        return;
    }
    dialog.saved = true;
    runtime().rows = dialog.config.rows;
    commitRows(dialog.config.rows);
    close(window);
}

constexpr jsti::chrome::DialogFrame dialogFrame{
    minimumClientWidth, minimumClientHeight, windowStyle, windowExStyle, listID, IDOK};

bool handle(HWND window, Dialog &dialog, UINT message, WPARAM wparam, LPARAM lparam, LRESULT &) {
    switch (message) {
    case WM_NOTIFY: {
        const auto header = reinterpret_cast<NMHDR *>(lparam);
        if (header->idFrom != static_cast<UINT_PTR>(listID) || header->code != LVN_ITEMCHANGED) return false;
        const auto change = reinterpret_cast<NMLISTVIEW *>(lparam);
        if ((change->uChanged & LVIF_STATE) && (change->uNewState & LVIS_SELECTED) &&
            !(change->uOldState & LVIS_SELECTED)) {
            dialog.selected = change->iItem;
            loadDetail(window, dialog);
        }
        return true;
    }
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case keyID: if (HIWORD(wparam) == EN_CHANGE) readDetail(window, dialog); return true;
        case enabledID: case globalID: if (HIWORD(wparam) == BN_CLICKED) readDetail(window, dialog); return true;
        case clearID:
            if (HIWORD(wparam) == BN_CLICKED) {
                SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, 0, 0);
                readDetail(window, dialog);
                SetFocus(GetDlgItem(window, keyID));
            }
            return true;
        case presetID:
            if (HIWORD(wparam) == CBN_SELCHANGE)
                applyPreset(window, dialog, static_cast<int>(SendDlgItemMessageW(window, presetID, CB_GETCURSEL, 0, 0)));
            return true;
        case resetID: if (HIWORD(wparam) == BN_CLICKED) applyPreset(window, dialog, 0); return true;
        case IDOK: if (HIWORD(wparam) == BN_CLICKED) save(window, dialog); return true;
        case IDCANCEL: if (HIWORD(wparam) == BN_CLICKED) close(window); return true;
        default: return false;
        }
        return false;
    }
    return false;
}

const jsti::chrome::DialogProcedure<Dialog> dialogParts{dialogFrame, layout, refreshFont, createControls, close, handle};

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return jsti::chrome::dialogProcedure(dialogParts, window, message, wparam, lparam);
}
} // namespace

HWND createDialog(HWND owner, Dialog &dialog) {
    dialog.owner = owner;
    return jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItActionShortcuts", procedure, L"Action shortcuts — Just Speak to It",
        760, 600, windowStyle, windowExStyle, &dialog);
}

} // namespace jsti::actionShortcuts
