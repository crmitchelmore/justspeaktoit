// General page: automation and Launch at login, owned by WindowsWindowGeneral.cpp.
// The host's reports arrive under WindowState::mutex; the note under App
// behaviour is UI-thread only.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

// The host's last automation and Launch at login reports.
struct GeneralSettings {
    bool automationEnabled = false;
    // The shared DesktopLoginItemState, -1 until the host reports it.
    int loginItem = -1;
    // A click waits for the state reached.
    bool loginItemPending = false;
    std::wstring loginItemDetail;
};

// These lock WindowState::mutex.
GeneralSettings generalSettings();
// Marks a Launch at login click pending and reports the state it asks for;
// false while one is pending or the system decides the switch.
bool claimLoginItemToggle(bool &requested);

// The caller holds WindowState::mutex.
void restoreLoginItem(int value, const std::wstring &detail);

// UI thread only: the note under App behaviour, shown when the system decides the switch.
const std::wstring &loginItemNote();
// Returns whether the note changed.
bool replaceLoginItemNote(std::wstring note);

} // namespace jsti_window
