#include "../CWindowsSupport/WindowsActionShortcutsInternal.hpp"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"
#include <commctrl.h>
#include <set>

namespace jsti::actionShortcuts {
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
bool selfTest(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    const std::vector<Row> originalRows = runtime().rows;
    const HWND originalOwner = runtime().owner;
    unregisterAll();
    Fixture local;
    fixture = &local;
    runtime().registerKey = fakeRegister;
    runtime().unregisterKey = fakeUnregister;
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
        if (!receiverRunning()) {
            std::string failure;
            createdReceiver = true;
            if (!jsti_action_shortcuts_start(owner, failure)) {
                error = "Action shortcuts did not start: " + failure; return false;
            }
        } else {
            runtime().owner = owner;
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
        // The save reached the host's configuration, and a dialog whose rows no
        // longer match the host's (the host replaced them meanwhile) stores nothing.
        const Configuration stored = snapshot();
        commitRows({stored.rows.front()});
        const Configuration kept = snapshot();
        if (stored.rows.size() != 3 || stored.rows.front().key != 'J' || kept.rows.size() != 3 ||
            !jsti_action_shortcuts_available()) {
            error = "An action shortcut save replaced rows the host had changed."; return false;
        }
        return true;
    };
    bool passed = false;
    try { passed = check(); }
    catch (const std::exception &) { error = "Action shortcut self-test could not allocate its state."; }
    unregisterAll();
    if (createdReceiver) jsti_action_shortcuts_stop();
    runtime().registerKey = RegisterHotKey;
    runtime().unregisterKey = UnregisterHotKey;
    fixture = nullptr;
    exchangeConfiguration(original);
    runtime().owner = createdReceiver ? nullptr : originalOwner;
    runtime().rows = originalRows;
    if (!createdReceiver) registerRows(runtime().rows);
    return passed;
}
} // namespace jsti::actionShortcuts

bool jsti_action_shortcuts_self_test(HWND owner, std::string &error) {
    return jsti::actionShortcuts::selfTest(owner, error);
}
