#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commctrl.h>
#include <cwchar>
#include <mutex>
#include <set>
#include <vector>

// The Mac's individual action shortcuts. The host sends one row per catalogue
// action with how Windows runs it; rows Windows cannot run stay listed so they
// round-trip to the Mac. Window-local rows are matched in the main message
// loop; rows that work in other apps are registered with RegisterHotKey on a
// message-only window, so the main window's dictation shortcut identifiers are
// never touched. Nothing installs a keyboard hook.

// Provided by WindowsWindow.cpp.
void jsti_window_action_command(HWND window, int run, const char *page);

namespace {
constexpr UINT applyMessage = WM_APP + 0x51, refreshMessage = WM_APP + 0x52;
constexpr int firstHotKeyID = 0x100;
constexpr size_t maximumRows = 64, maximumPresets = 8;

struct Row {
    std::string identifier, title, note, page;
    std::wstring wideTitle, wideNote;
    int run = JSTI_ACTION_RUN_NONE;
    UINT modifiers = 0, key = 0;
    bool enabled = false, global = false, canBeGlobal = false;
};

struct Configuration {
    std::vector<Row> rows;
    std::vector<std::wstring> presetNames;
    std::vector<std::vector<Row>> presets;
    JSTIActionShortcutsCallback callback = nullptr;
    JSTIActionShortcutsRefresh refresh = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;
HWND receiver = nullptr;  // guarded by configurationMutex; created and destroyed on the UI thread

// UI thread only.
struct Runtime {
    HWND owner = nullptr;
    std::vector<Row> rows;
    std::vector<int> registered;
    BOOL (WINAPI *registerKey)(HWND, int, UINT, UINT) = RegisterHotKey;
    BOOL (WINAPI *unregisterKey)(HWND, int) = UnregisterHotKey;
} runtime;

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

bool modifierKey(UINT key) {
    switch (key) {
    case VK_SHIFT: case VK_CONTROL: case VK_MENU: case VK_LSHIFT: case VK_RSHIFT: case VK_LCONTROL:
    case VK_RCONTROL: case VK_LMENU: case VK_RMENU: case VK_LWIN: case VK_RWIN: case VK_CAPITAL:
    case VK_NUMLOCK: case VK_SCROLL: return true;
    default: return false;
    }
}

bool validKey(UINT modifiers, UINT key) {
    if (modifiers & ~static_cast<UINT>(MOD_ALT | MOD_CONTROL | MOD_SHIFT)) return false;
    return key == 0 ? modifiers == 0 : key < 0xFF && !modifierKey(key);
}

// Other apps keep ordinary typing: a system-wide shortcut needs Ctrl or Alt,
// or one of the keys no keyboard types with (F13-F24).
bool globalCombination(UINT modifiers, UINT key) {
    return key != 0 && ((modifiers & (MOD_ALT | MOD_CONTROL)) || (key >= VK_F13 && key <= VK_F24));
}

bool runnable(const Row &row) { return row.run != JSTI_ACTION_RUN_NONE && row.enabled && row.key != 0; }
bool registersGlobally(const Row &row) {
    return runnable(row) && row.global && row.canBeGlobal && globalCombination(row.modifiers, row.key);
}

bool extendedKey(UINT key) {
    switch (key) {
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_PRIOR: case VK_NEXT: case VK_END:
    case VK_HOME: case VK_INSERT: case VK_DELETE: case VK_DIVIDE: case VK_NUMLOCK: return true;
    default: return false;
    }
}

std::wstring keyName(UINT key) {
    UINT scan = MapVirtualKeyW(key, MAPVK_VK_TO_VSC);
    if (extendedKey(key)) scan |= 0x100;
    wchar_t text[64] = {};
    if (scan && GetKeyNameTextW(static_cast<LONG>(scan << 16), text, 64) > 0) return text;
    wchar_t fallback[16] = {};
    std::swprintf(fallback, 16, L"Key 0x%02X", key);
    return fallback;
}

std::wstring comboName(UINT modifiers, UINT key) {
    if (!key) return L"Not set";
    std::wstring name;
    if (modifiers & MOD_CONTROL) name += L"Ctrl+";
    if (modifiers & MOD_ALT) name += L"Alt+";
    if (modifiers & MOD_SHIFT) name += L"Shift+";
    return name + keyName(key);
}

std::wstring whereText(const Row &row) {
    if (row.run == JSTI_ACTION_RUN_NONE) return L"Mac only";
    if (!row.enabled) return L"Off";
    if (!row.key) return L"Not set";
    return registersGlobally(row) ? L"All apps" : L"This window";
}

std::wstring noteText(const Row &row) {
    if (!row.wideNote.empty()) return row.wideNote;
    if (row.run != JSTI_ACTION_RUN_NONE && row.enabled && row.global && row.canBeGlobal && row.key &&
        !globalCombination(row.modifiers, row.key)) return L"Add Ctrl or Alt to use it in other apps.";
    return L"";
}

std::vector<JSTIActionShortcut> view(const std::vector<Row> &rows) {
    std::vector<JSTIActionShortcut> result;
    result.reserve(rows.size());
    for (const Row &row : rows) {
        result.push_back(JSTIActionShortcut{row.identifier.c_str(), row.title.c_str(),
            row.note.empty() ? nullptr : row.note.c_str(), row.page.c_str(), row.run, row.modifiers, row.key,
            row.enabled ? 1 : 0, row.global ? 1 : 0, row.canBeGlobal ? 1 : 0});
    }
    return result;
}

void unregisterAll() {
    HWND target = receiver;
    for (int id : runtime.registered) runtime.unregisterKey(target, id);
    runtime.registered.clear();
}

// Registers every eligible row, returning the combinations Windows refused.
std::vector<std::wstring> registerRows(const std::vector<Row> &rows) {
    unregisterAll();
    std::vector<std::wstring> failures;
    if (!receiver) return failures;
    for (size_t index = 0; index < rows.size(); ++index) {
        const Row &row = rows[index];
        if (!registersGlobally(row)) continue;
        const int id = firstHotKeyID + static_cast<int>(index);
        if (runtime.registerKey(receiver, id, row.modifiers | MOD_NOREPEAT, row.key)) runtime.registered.push_back(id);
        else failures.push_back(comboName(row.modifiers, row.key) + L" (" + row.wideTitle + L")");
    }
    return failures;
}

std::wstring failureText(const std::vector<std::wstring> &failures) {
    std::wstring text;
    for (const auto &failure : failures) text += (text.empty() ? L"" : L", ") + failure;
    return text + (failures.size() == 1 ? L" is" : L" are") +
        L" already used by Windows or another app, so it works only in this window.";
}

void apply(bool announce) {
    runtime.rows = snapshot().rows;
    const auto failures = registerRows(runtime.rows);
    if (!announce || failures.empty()) return;
    jsti_window_update(jsti::utf8(failureText(failures)).c_str(), nullptr, -1);
}

LRESULT CALLBACK receiverProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case applyMessage: apply(true); return 0;
    case refreshMessage: {
        const Configuration config = snapshot();
        if (config.refresh) config.refresh(config.context);
        return 0;
    }
    case WM_HOTKEY: {
        const int index = static_cast<int>(wparam) - firstHotKeyID;
        // A modal dialog disables the owner; it gets the keys back when it closes.
        if (index < 0 || static_cast<size_t>(index) >= runtime.rows.size() || !runtime.owner ||
            !IsWindowEnabled(runtime.owner)) return 0;
        const Row row = runtime.rows[static_cast<size_t>(index)];
        if (registersGlobally(row)) jsti_window_action_command(runtime.owner, row.run, row.page.c_str());
        return 0;
    }
    default: return DefWindowProcW(window, message, wparam, lparam);
    }
}

bool focusedClass(HWND focus, std::initializer_list<const wchar_t *> names) {
    if (!focus) return false;
    wchar_t name[128] = {};
    GetClassNameW(focus, name, 128);
    for (const wchar_t *candidate : names) if (_wcsnicmp(name, candidate, std::wcslen(candidate)) == 0) return true;
    return false;
}

// Keys a focused control needs for itself keep their usual meaning.
bool belongsToFocus(HWND focus, UINT modifiers, UINT key) {
    const bool plain = (modifiers & ~static_cast<UINT>(MOD_SHIFT)) == 0;
    if (focusedClass(focus, {HOTKEY_CLASSW})) return true;
    if (focusedClass(focus, {L"Edit", L"RichEdit"})) {
        if (plain) return true;
        if (modifiers == MOD_CONTROL || modifiers == (MOD_CONTROL | MOD_SHIFT)) {
            switch (key) {
            case 'A': case 'C': case 'V': case 'X': case 'Y': case 'Z': case VK_BACK: case VK_DELETE: case VK_LEFT:
            case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_HOME: case VK_END: case VK_INSERT: return true;
            default: break;
            }
        }
    }
    if (plain && focusedClass(focus, {L"ComboBox", WC_LISTVIEWW, WC_TREEVIEWW, L"ListBox", TRACKBAR_CLASSW}))
        return true;
    return plain && (key == VK_SPACE || key == VK_RETURN) && focusedClass(focus, {L"Button"});
}

// ---- Action shortcuts dialog ----------------------------------------------

enum Control { introID = 900, listID, keyLabelID, keyID, clearID, enabledID, globalID, noteID, presetLabelID, presetID,
               resetID, statusID };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 720, minimumClientHeight = 540;

struct Dialog {
    Configuration config;
    HWND owner = nullptr;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    int selected = -1;
    bool loading = false, saved = false;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

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

void refreshFont(HWND window, Dialog &dialog) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return;
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = font;
}

WORD hotkeyValue(UINT modifiers, UINT key) {
    BYTE flags = 0;
    if (modifiers & MOD_SHIFT) flags |= HOTKEYF_SHIFT;
    if (modifiers & MOD_CONTROL) flags |= HOTKEYF_CONTROL;
    if (modifiers & MOD_ALT) flags |= HOTKEYF_ALT;
    if (extendedKey(key)) flags |= HOTKEYF_EXT;
    return MAKEWORD(static_cast<BYTE>(key), flags);
}

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

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

void save(HWND window, Dialog &dialog) {
    if (dialog.saved || check(window, dialog, false) != 0) return;
    // Probe the new set before the host stores it; a refusal keeps the old one.
    const auto failures = registerRows(dialog.config.rows);
    if (!failures.empty()) {
        registerRows(runtime.rows);
        const std::wstring message = failureText(failures).substr(0, failureText(failures).find(L", so it")) +
            L". Choose another shortcut or turn off Works in other apps.";
        SetDlgItemTextW(window, statusID, message.c_str());
        return;
    }
    if (check(window, dialog, true) != 0) {
        registerRows(runtime.rows);
        return;
    }
    dialog.saved = true;
    runtime.rows = dialog.config.rows;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        if (configuration.rows.size() == dialog.config.rows.size()) configuration.rows = dialog.config.rows;
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
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, listID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_NOTIFY: {
        const auto header = reinterpret_cast<NMHDR *>(lparam);
        if (header->idFrom != static_cast<UINT_PTR>(listID) || header->code != LVN_ITEMCHANGED) break;
        const auto change = reinterpret_cast<NMLISTVIEW *>(lparam);
        if ((change->uChanged & LVIF_STATE) && (change->uNewState & LVIS_SELECTED) &&
            !(change->uOldState & LVIS_SELECTED)) {
            dialog->selected = change->iItem;
            loadDetail(window, *dialog);
        }
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case keyID: if (HIWORD(wparam) == EN_CHANGE) readDetail(window, *dialog); return 0;
        case enabledID: case globalID: if (HIWORD(wparam) == BN_CLICKED) readDetail(window, *dialog); return 0;
        case clearID:
            if (HIWORD(wparam) == BN_CLICKED) {
                SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, 0, 0);
                readDetail(window, *dialog);
                SetFocus(GetDlgItem(window, keyID));
            }
            return 0;
        case presetID:
            if (HIWORD(wparam) == CBN_SELCHANGE)
                applyPreset(window, *dialog, static_cast<int>(SendDlgItemMessageW(window, presetID, CB_GETCURSEL, 0, 0)));
            return 0;
        case resetID: if (HIWORD(wparam) == BN_CLICKED) applyPreset(window, *dialog, 0); return 0;
        case IDOK: if (HIWORD(wparam) == BN_CLICKED) save(window, *dialog); return 0;
        case IDCANCEL: if (HIWORD(wparam) == BN_CLICKED) close(window); return 0;
        default: break;
        }
        break;
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
    type.lpszClassName = L"JustSpeakToItActionShortcuts";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 760), scale(owner, 600)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    dialog.owner = owner;
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Action shortcuts — Just Speak to It", windowStyle,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}

bool parseRow(const JSTIActionShortcut &source, Row &row, bool keysOnly) {
    if (!validKey(source.modifiers, source.virtual_key)) return false;
    row.modifiers = source.modifiers;
    row.key = source.virtual_key;
    row.enabled = source.enabled != 0;
    row.global = source.global != 0;
    if (keysOnly) return true;
    if (!source.identifier || !*source.identifier || std::strlen(source.identifier) > 128 || !source.title ||
        !jsti::wide(source.title, row.wideTitle) || row.wideTitle.empty() || row.wideTitle.size() > 128) return false;
    if (source.note && (!jsti::wide(source.note, row.wideNote) || row.wideNote.size() > 512)) return false;
    switch (source.run) {
    case JSTI_ACTION_RUN_NONE: case JSTI_ACTION_RUN_RECORD: case JSTI_ACTION_RUN_PLAY_PAUSE:
    case JSTI_ACTION_RUN_STOP_SPEECH: case JSTI_ACTION_RUN_API_KEYS: case JSTI_ACTION_RUN_PERMISSIONS:
    case JSTI_ACTION_RUN_COMPARE: case JSTI_ACTION_RUN_QUICK_VOICE_1: case JSTI_ACTION_RUN_QUICK_VOICE_2:
    case JSTI_ACTION_RUN_QUICK_VOICE_3: case JSTI_ACTION_RUN_PASTE_LAST_HISTORY:
    case JSTI_ACTION_RUN_SPEAK_SELECTED_TEXT: case JSTI_ACTION_RUN_SPEAK_CLIPBOARD:
    case JSTI_ACTION_RUN_TROUBLESHOOTING: break;
    case JSTI_ACTION_RUN_PAGE:
        if (!source.page || !*source.page || std::strlen(source.page) > 64) return false;
        row.page = source.page;
        break;
    default: return false;
    }
    row.identifier = source.identifier;
    row.title = source.title;
    row.note = source.note ? source.note : "";
    row.run = source.run;
    row.canBeGlobal = source.can_be_global != 0;
    return true;
}
} // namespace

// ---- window integration ----------------------------------------------------

// Creates the receiver for system-wide action shortcuts and registers them.
// On failure the rows still work inside the window and the message says which.
bool jsti_action_shortcuts_start(HWND owner, std::string &failure) {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = receiverProcedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItActionShortcutReceiver";
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        failure = jsti::systemError("Preparing action shortcuts");
        return false;
    }
    HWND created = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
    if (!created) {
        failure = jsti::systemError("Preparing action shortcuts");
        return false;
    }
    runtime.owner = owner;
    { std::lock_guard<std::mutex> lock(configurationMutex); receiver = created; }
    runtime.rows = snapshot().rows;
    const auto failures = registerRows(runtime.rows);
    if (failures.empty()) return true;
    failure = jsti::utf8(failureText(failures));
    return false;
}

void jsti_action_shortcuts_stop() {
    unregisterAll();
    HWND destroyed = nullptr;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        destroyed = receiver;
        receiver = nullptr;
    }
    if (destroyed) DestroyWindow(destroyed);
    runtime.owner = nullptr;
    runtime.rows.clear();
}

// Asks the host to read its bindings again, for example after an import.
void jsti_action_shortcuts_request_refresh() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    if (receiver && configuration.refresh) PostMessageW(receiver, refreshMessage, 0, 0);
}

// Window-local rows, from the main message loop. Returns true when handled.
bool jsti_action_shortcut_key_message(HWND window, const MSG &message) {
    if ((message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) || (message.lParam & (1L << 30)) ||
        !(message.hwnd == window || IsChild(window, message.hwnd)) || !IsWindowEnabled(window) ||
        runtime.rows.empty()) return false;
    const UINT key = static_cast<UINT>(message.wParam);
    if (modifierKey(key) || (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) return false;
    const UINT modifiers = ((GetKeyState(VK_CONTROL) & 0x8000) ? MOD_CONTROL : 0) |
        ((GetKeyState(VK_MENU) & 0x8000) ? MOD_ALT : 0) | ((GetKeyState(VK_SHIFT) & 0x8000) ? MOD_SHIFT : 0);
    for (const Row &row : runtime.rows) {
        if (!runnable(row) || row.key != key || row.modifiers != modifiers) continue;
        if (belongsToFocus(GetFocus(), modifiers, key)) return false;
        const Row chosen = row;
        jsti_window_action_command(window, chosen.run, chosen.page.c_str());
        return true;
    }
    return false;
}

void jsti_show_action_shortcuts(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback || dialog.config.rows.empty()) return;
    if (runtime.rows.size() == dialog.config.rows.size()) dialog.config.rows = runtime.rows;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening action shortcuts").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, listID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading action shortcut messages").c_str(), nullptr, -1);
}

bool jsti_action_shortcuts_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr && !configuration.rows.empty();
}

int jsti_window_set_action_shortcuts(const JSTIActionShortcut *rows, size_t count, const char *const *presetNames,
                                     const JSTIActionShortcut *presetRows, size_t presetCount,
                                     JSTIActionShortcutsCallback callback, JSTIActionShortcutsRefresh refresh,
                                     void *context) {
    if (!rows || !count || count > maximumRows || !callback || presetCount > maximumPresets ||
        (presetCount && (!presetNames || !presetRows))) return -1;
    try {
        Configuration updated;
        std::set<std::string> identifiers;
        for (size_t index = 0; index < count; ++index) {
            Row row;
            if (!parseRow(rows[index], row, false) || !identifiers.insert(row.identifier).second) return -1;
            updated.rows.push_back(std::move(row));
        }
        for (size_t preset = 0; preset < presetCount; ++preset) {
            std::wstring name;
            if (!jsti::wide(presetNames[preset], name) || name.empty() || name.size() > 64) return -1;
            std::vector<Row> block = updated.rows;
            for (size_t index = 0; index < count; ++index) {
                if (!parseRow(presetRows[preset * count + index], block[index], true)) return -1;
            }
            updated.presetNames.push_back(std::move(name));
            updated.presets.push_back(std::move(block));
        }
        updated.callback = callback;
        updated.refresh = refresh;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
        if (receiver) PostMessageW(receiver, applyMessage, 0, 0);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_action_shortcuts(void) {
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = Configuration();
        if (receiver) PostMessageW(receiver, applyMessage, 0, 0);
    }
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Fixture {
    std::set<std::pair<UINT, UINT>> taken;
    std::vector<std::pair<int, std::pair<UINT, UINT>>> registered;
    int checks = 0, commits = 0;
    bool refuse = false;
    UINT committedKey = 0;
} *fixture = nullptr;

BOOL WINAPI fakeRegister(HWND, int id, UINT modifiers, UINT key) {
    const auto combination = std::make_pair(modifiers & ~static_cast<UINT>(MOD_NOREPEAT), key);
    if (fixture->taken.count(combination)) return FALSE;
    for (const auto &entry : fixture->registered) if (entry.first == id || entry.second == combination) return FALSE;
    fixture->registered.push_back({id, combination});
    return TRUE;
}

BOOL WINAPI fakeUnregister(HWND, int id) {
    auto &entries = fixture->registered;
    const auto before = entries.size();
    entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const auto &entry) { return entry.first == id; }),
                  entries.end());
    return entries.size() != before;
}

int fakeCheck(const JSTIActionShortcut *rows, size_t count, int commit, char *message, size_t capacity, void *) {
    ++fixture->checks;
    if (fixture->refuse) return jsti::fail("Refused by host.", message, capacity);
    if (commit) {
        ++fixture->commits;
        fixture->committedKey = count ? rows[0].virtual_key : 0;
    }
    return 0;
}

void clickButton(HWND window, int id) {
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
}
} // namespace

// Configuration checks, system-wide registration and the dialog's save path
// against fake registration: no shortcut is taken and no key is read.
bool jsti_action_shortcuts_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    const std::vector<Row> originalRows = runtime.rows;
    const HWND originalOwner = runtime.owner;
    unregisterAll();
    Fixture local;
    fixture = &local;
    runtime.registerKey = fakeRegister;
    runtime.unregisterKey = fakeUnregister;
    bool createdReceiver = false;
    auto check = [&]() -> bool {
        JSTIActionShortcut rows[] = {
            {"startStopRecording", "Start or stop recording", nullptr, nullptr, JSTI_ACTION_RUN_RECORD,
             MOD_CONTROL | MOD_SHIFT, 'S', 1, 1, 1},
            {"showHistory", "Show History", nullptr, "history", JSTI_ACTION_RUN_PAGE, MOD_CONTROL, 'Y', 1, 1, 0},
            {"speakClipboard", "Speak clipboard", "Mac only", nullptr, JSTI_ACTION_RUN_NONE, 0, 0, 1, 1, 0}};
        const char *names[] = {"Standard"};
        JSTIActionShortcut unsafe = rows[0];
        unsafe.modifiers = MOD_WIN;
        JSTIActionShortcut missingPage = rows[1];
        missingPage.page = nullptr;
        if (jsti_window_set_action_shortcuts(&unsafe, 1, nullptr, nullptr, 0, fakeCheck, nullptr, nullptr) != -1 ||
            jsti_window_set_action_shortcuts(&missingPage, 1, nullptr, nullptr, 0, fakeCheck, nullptr, nullptr) != -1 ||
            jsti_window_set_action_shortcuts(rows, 3, names, rows, 1, nullptr, nullptr, nullptr) != -1 ||
            jsti_window_set_action_shortcuts(rows, 3, names, rows, 1, fakeCheck, nullptr, nullptr) != 0) {
            error = "Action shortcut configuration accepted an unsafe row or rejected a valid one."; return false;
        }
        if (!receiver) {
            std::string failure;
            createdReceiver = true;
            if (!jsti_action_shortcuts_start(owner, failure)) {
                error = "Action shortcuts did not start: " + failure; return false;
            }
        } else {
            runtime.owner = owner;
            apply(false);
        }
        // Only the row that may work in other apps is registered.
        if (local.registered.size() != 1 || local.registered.front().second != std::make_pair(
                static_cast<UINT>(MOD_CONTROL | MOD_SHIFT), static_cast<UINT>('S'))) {
            error = "Action shortcuts registered the wrong rows system-wide."; return false;
        }
        // A taken combination keeps the dialog open and the old registration.
        local.taken.insert({MOD_CONTROL | MOD_ALT, 'R'});
        Dialog dialog;
        dialog.config = snapshot();
        HWND window = createDialog(owner, dialog);
        if (!window) { error = jsti::systemError("Creating the action shortcut fixture"); return false; }
        SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(MOD_CONTROL | MOD_ALT, 'R'), 0);
        readDetail(window, dialog);
        clickButton(window, IDOK);
        wchar_t status[512] = {};
        GetDlgItemTextW(window, statusID, status, 512);
        if (!IsWindow(window) || local.commits != 0 || local.registered.size() != 1 ||
            local.registered.front().second.second != 'S' || std::wstring(status).find(L"already used") == std::wstring::npos) {
            if (IsWindow(window)) DestroyWindow(window);
            error = "A taken action shortcut was saved, changed registration or was not explained."; return false;
        }
        // The host may refuse; the registration stays as it was.
        SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(MOD_CONTROL | MOD_ALT, 'J'), 0);
        readDetail(window, dialog);
        local.refuse = true;
        clickButton(window, IDOK);
        local.refuse = false;
        if (!IsWindow(window) || local.commits != 0 || local.registered.front().second.second != 'S') {
            if (IsWindow(window)) DestroyWindow(window);
            error = "A refused action shortcut closed the dialog or changed registration."; return false;
        }
        // Presets restore the defaults, and an available combination saves.
        SendDlgItemMessageW(window, presetID, CB_SETCURSEL, 0, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(presetID, CBN_SELCHANGE),
                     reinterpret_cast<LPARAM>(GetDlgItem(window, presetID)));
        if (dialog.config.rows[0].key != 'S' || dialog.config.rows[0].modifiers != static_cast<UINT>(MOD_CONTROL | MOD_SHIFT)) {
            DestroyWindow(window);
            error = "Choosing a preset did not restore its shortcuts."; return false;
        }
        SendDlgItemMessageW(window, keyID, HKM_SETHOTKEY, hotkeyValue(MOD_CONTROL | MOD_ALT, 'J'), 0);
        readDetail(window, dialog);
        clickButton(window, IDOK);
        const bool saved = !IsWindow(window);
        if (IsWindow(window)) DestroyWindow(window);
        if (!saved || local.commits != 1 || local.committedKey != 'J' || local.registered.size() != 1 ||
            local.registered.front().second.second != 'J') {
            error = "An available action shortcut was not saved and registered."; return false;
        }
        return true;
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { error = "Action shortcut self-test could not allocate its state."; }
    unregisterAll();
    if (createdReceiver) jsti_action_shortcuts_stop();
    runtime.registerKey = RegisterHotKey;
    runtime.unregisterKey = UnregisterHotKey;
    fixture = nullptr;
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = original; }
    runtime.owner = createdReceiver ? nullptr : originalOwner;
    runtime.rows = originalRows;
    if (!createdReceiver) registerRows(runtime.rows);
    return passed;
}
