// Housekeeping confirmations staged for the UI thread, owned by
// WindowsWindowBackup.cpp. Each function requires WindowState::mutex.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

// Moves out the pending audio cleanup token (empty when none) and its count.
void takeAudioCleanup(std::string &token, size_t &count);
// Moves out the pending read-only backup report (empty when none).
std::wstring takeMigrationReport();
// The window closed: nothing staged may be shown.
void retireHousekeeping();

} // namespace jsti_window
