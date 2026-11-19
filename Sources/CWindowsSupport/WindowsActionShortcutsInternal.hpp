// Action shortcuts: the host's configuration, system-wide registration and the
// window integration (WindowsActionShortcuts.cpp), the editor dialog
// (WindowsActionShortcutsDialog.cpp) and the pieces the self-test
// (CWindowsSelfTest/WindowsActionShortcutsSelfTest.cpp) drives. Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <string>
#include <vector>

namespace jsti::actionShortcuts {

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

// UI thread only.
struct Runtime {
    HWND owner = nullptr;
    std::vector<Row> rows;
    std::vector<int> registered;
    BOOL (WINAPI *registerKey)(HWND, int, UINT, UINT) = RegisterHotKey;
    BOOL (WINAPI *unregisterKey)(HWND, int) = UnregisterHotKey;
};

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

// The host's configuration and receiver (WindowsActionShortcuts.cpp). They are
// shared with the host's threads behind one mutex; these take it.
Configuration snapshot();
Configuration exchangeConfiguration(Configuration next);
// Stores the dialog's saved rows while the host's row count still matches them.
void commitRows(const std::vector<Row> &rows);
bool receiverRunning();
// UI thread only.
Runtime &runtime();

// Keys and registration (WindowsActionShortcuts.cpp). Registration is UI thread only.
bool modifierKey(UINT key);
bool extendedKey(UINT key);
std::wstring comboName(UINT modifiers, UINT key);
std::wstring whereText(const Row &row);
std::wstring noteText(const Row &row);
std::vector<JSTIActionShortcut> view(const std::vector<Row> &rows);
void unregisterAll();
// Registers every eligible row, returning the combinations Windows refused.
std::vector<std::wstring> registerRows(const std::vector<Row> &rows);
std::wstring failureText(const std::vector<std::wstring> &failures);
void apply(bool announce);

// The dialog (WindowsActionShortcutsDialog.cpp). UI thread only.
WORD hotkeyValue(UINT modifiers, UINT key);
void readDetail(HWND window, Dialog &dialog);
void close(HWND window);
HWND createDialog(HWND owner, Dialog &dialog);

} // namespace jsti::actionShortcuts
