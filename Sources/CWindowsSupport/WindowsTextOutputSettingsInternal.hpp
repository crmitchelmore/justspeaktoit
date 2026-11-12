// Text output settings: the host's configuration (WindowsTextOutputSettings.cpp),
// the modal dialog (WindowsTextOutputSettingsDialog.cpp) and the pieces their
// self-test (WindowsTextOutputSettingsSelfTest.cpp) drives. Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <string>
#include <vector>

// Whether the host configured Text output; also declared for the window in
// WindowsWindowInternal.hpp.
bool jsti_text_output_available();

namespace jsti::textOutputSettings {

enum Control {
    introID = 700, methodGroupID, smartID, directID, clipboardID, noteID,
    insertionGroupID, cursorID, replaceID, restoreID, appSwitchLabelID, appSwitchID, appSwitchHelpID
};
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VSCROLL;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 260, preferredClientHeight = 670;

struct Choice {
    int method = JSTI_TEXT_OUTPUT_SMART;
    int insertion = JSTI_TEXT_OUTPUT_AT_CURSOR;
    bool restore = true;
    bool operator==(const Choice &other) const {
        return method == other.method && insertion == other.insertion && restore == other.restore;
    }
};
struct Configuration {
    Choice choice;
    std::wstring appSwitchTitle, appSwitchHelp;
    std::vector<std::wstring> appSwitchLabels;
    int appSwitchSelection = 0;
    JSTITextOutputSettingsCallback callback = nullptr;
    void *context = nullptr;
};
struct Dialog {
    Configuration config;
    Choice choice;
    int appSwitchSelection = 0;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool applied = false;
    int scroll = 0;
    int wheelRemainder = 0;
};

// Insertion applies to both inserting methods. Restoration applies only to a
// Smart paste at the cursor: replacing a field and direct insertion never paste.
inline bool insertionApplies(const Choice &choice) { return choice.method != JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY; }
inline bool restoreApplies(const Choice &choice) {
    return choice.method == JSTI_TEXT_OUTPUT_SMART && choice.insertion == JSTI_TEXT_OUTPUT_AT_CURSOR;
}

// The host's configuration is private to WindowsTextOutputSettings.cpp, behind
// its mutex. These take the lock; the self-test swaps fixtures in and out.
Configuration configurationSnapshot();
Configuration exchangeConfiguration(Configuration next);
// Calls the dialog's borrowed callback with its applied draft. While it runs,
// jsti_window_app_switch_selection() on this thread reports the draft's
// app-switch choice rather than the stored one.
void deliverApply(const Configuration &config, const Choice &choice, int appSwitchSelection);

// The dialog (WindowsTextOutputSettingsDialog.cpp). UI thread only.
RECT fitWorkArea(RECT proposed, const RECT &work);
void layout(HWND window);
void revealControl(HWND window, HWND control);
bool routeDialogKey(HWND window, MSG &message);
HWND createDialog(HWND owner, Dialog &dialog);

// Self-test only, UI thread: the next jsti_show_text_output runs `check` inside
// its modal loop after the owner has been disabled, then closes the dialog
// through Escape without applying. takeProbe reports and disarms it.
struct ProbeResult {
    bool opened = false, passed = false, timedOut = false;
};
void armProbe(bool (*check)(HWND owner, void *context), void *context);
ProbeResult takeProbe();

} // namespace jsti::textOutputSettings
