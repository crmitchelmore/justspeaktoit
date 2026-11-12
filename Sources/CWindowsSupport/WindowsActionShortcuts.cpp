#include "WindowsActionShortcutsInternal.hpp"
#include "WindowsWindowChrome.hpp"
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

// Provided by WindowsWindowBridge.cpp.
void jsti_window_action_command(HWND window, int run, const char *page);

namespace jsti::actionShortcuts {
namespace {
constexpr UINT applyMessage = WM_APP + 0x51, refreshMessage = WM_APP + 0x52;
constexpr int firstHotKeyID = 0x100;
constexpr size_t maximumRows = 64, maximumPresets = 8;

// The host's rows and presets, and the receiver for system-wide shortcuts. The
// host's threads and the UI thread share them under `mutex`; the receiver is
// created and destroyed on the UI thread.
struct Shared {
    std::mutex mutex;
    Configuration configuration;
    HWND receiver = nullptr;
};
Shared &shared() {
    static Shared value;
    return value;
}

} // namespace

Runtime &runtime() {
    static Runtime value;
    return value;
}
Configuration snapshot() {
    std::lock_guard<std::mutex> lock(shared().mutex);
    return shared().configuration;
}
Configuration exchangeConfiguration(Configuration next) {
    std::lock_guard<std::mutex> lock(shared().mutex);
    std::swap(shared().configuration, next);
    return next;
}
void commitRows(const std::vector<Row> &rows) {
    std::lock_guard<std::mutex> lock(shared().mutex);
    if (shared().configuration.rows.size() == rows.size()) shared().configuration.rows = rows;
}
bool receiverRunning() {
    std::lock_guard<std::mutex> lock(shared().mutex);
    return shared().receiver != nullptr;
}

bool modifierKey(UINT key) {
    switch (key) {
    case VK_SHIFT: case VK_CONTROL: case VK_MENU: case VK_LSHIFT: case VK_RSHIFT: case VK_LCONTROL:
    case VK_RCONTROL: case VK_LMENU: case VK_RMENU: case VK_LWIN: case VK_RWIN: case VK_CAPITAL:
    case VK_NUMLOCK: case VK_SCROLL: return true;
    default: return false;
    }
}

namespace {
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
} // namespace

bool extendedKey(UINT key) {
    switch (key) {
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_PRIOR: case VK_NEXT: case VK_END:
    case VK_HOME: case VK_INSERT: case VK_DELETE: case VK_DIVIDE: case VK_NUMLOCK: return true;
    default: return false;
    }
}

namespace {
std::wstring keyName(UINT key) {
    UINT scan = MapVirtualKeyW(key, MAPVK_VK_TO_VSC);
    if (extendedKey(key)) scan |= 0x100;
    wchar_t text[64] = {};
    if (scan && GetKeyNameTextW(static_cast<LONG>(scan << 16), text, 64) > 0) return text;
    wchar_t fallback[16] = {};
    std::swprintf(fallback, 16, L"Key 0x%02X", key);
    return fallback;
}

} // namespace

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
    HWND target = shared().receiver;
    for (int id : runtime().registered) runtime().unregisterKey(target, id);
    runtime().registered.clear();
}

// Registers every eligible row, returning the combinations Windows refused.
std::vector<std::wstring> registerRows(const std::vector<Row> &rows) {
    unregisterAll();
    std::vector<std::wstring> failures;
    const HWND receiver = shared().receiver;
    if (!receiver) return failures;
    for (size_t index = 0; index < rows.size(); ++index) {
        const Row &row = rows[index];
        if (!registersGlobally(row)) continue;
        const int id = firstHotKeyID + static_cast<int>(index);
        if (runtime().registerKey(receiver, id, row.modifiers | MOD_NOREPEAT, row.key)) runtime().registered.push_back(id);
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
    runtime().rows = snapshot().rows;
    const auto failures = registerRows(runtime().rows);
    if (!announce || failures.empty()) return;
    jsti_window_update(jsti::utf8(failureText(failures)).c_str(), nullptr, -1);
}

namespace {
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
        if (index < 0 || static_cast<size_t>(index) >= runtime().rows.size() || !runtime().owner ||
            !IsWindowEnabled(runtime().owner)) return 0;
        const Row row = runtime().rows[static_cast<size_t>(index)];
        if (registersGlobally(row)) jsti_window_action_command(runtime().owner, row.run, row.page.c_str());
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
    case JSTI_ACTION_RUN_TROUBLESHOOTING: case JSTI_ACTION_RUN_VOICE_EDIT: break;
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
} // namespace jsti::actionShortcuts

using namespace jsti::actionShortcuts;

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
    runtime().owner = owner;
    { std::lock_guard<std::mutex> lock(shared().mutex); shared().receiver = created; }
    runtime().rows = snapshot().rows;
    const auto failures = registerRows(runtime().rows);
    if (failures.empty()) return true;
    failure = jsti::utf8(failureText(failures));
    return false;
}

void jsti_action_shortcuts_stop() {
    unregisterAll();
    HWND destroyed = nullptr;
    {
        auto &state = shared();
        std::lock_guard<std::mutex> lock(state.mutex);
        destroyed = state.receiver;
        state.receiver = nullptr;
    }
    if (destroyed) DestroyWindow(destroyed);
    runtime().owner = nullptr;
    runtime().rows.clear();
}

// Asks the host to read its bindings again, for example after an import.
void jsti_action_shortcuts_request_refresh() {
    auto &state = shared();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.receiver && state.configuration.refresh) PostMessageW(state.receiver, refreshMessage, 0, 0);
}

// Window-local rows, from the main message loop. Returns true when handled.
bool jsti_action_shortcut_key_message(HWND window, const MSG &message) {
    if ((message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) || (message.lParam & (1L << 30)) ||
        !(message.hwnd == window || IsChild(window, message.hwnd)) || !IsWindowEnabled(window) ||
        runtime().rows.empty()) return false;
    const UINT key = static_cast<UINT>(message.wParam);
    if (modifierKey(key) || (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) return false;
    const UINT modifiers = ((GetKeyState(VK_CONTROL) & 0x8000) ? MOD_CONTROL : 0) |
        ((GetKeyState(VK_MENU) & 0x8000) ? MOD_ALT : 0) | ((GetKeyState(VK_SHIFT) & 0x8000) ? MOD_SHIFT : 0);
    for (const Row &row : runtime().rows) {
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
    if (runtime().rows.size() == dialog.config.rows.size()) dialog.config.rows = runtime().rows;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening action shortcuts").c_str(), nullptr, -1);
        return;
    }
    jsti::chrome::runModalDialog(owner, window, listID, close, "action shortcut");
}

bool jsti_action_shortcuts_available() {
    auto &state = shared();
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.configuration.callback != nullptr && !state.configuration.rows.empty();
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
        auto &state = shared();
        std::lock_guard<std::mutex> lock(state.mutex);
        state.configuration = std::move(updated);
        if (state.receiver) PostMessageW(state.receiver, applyMessage, 0, 0);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_action_shortcuts(void) {
    {
        auto &state = shared();
        std::lock_guard<std::mutex> lock(state.mutex);
        state.configuration = Configuration();
        if (state.receiver) PostMessageW(state.receiver, applyMessage, 0, 0);
    }
    jsti_window_update(nullptr, nullptr, -1);
}
